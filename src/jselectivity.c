/*
 * jselectivity.c -- RESTRICT estimators for the <, <=, > and >= operators of
 * jdate, jtimestamp and jtimestamptz (same-type and cross-type).
 *
 * Why not core's scalarltsel and friends: they work, but only to the
 * resolution of one histogram bucket. Their interpolation inside a bucket
 * (convert_to_scalar) knows only the built-in types, so for an extension type
 * the position of a constant inside its bucket is taken as 0.5. A narrow
 * two-sided predicate (`ts >= a AND ts < b`, both inside one bucket, which is
 * the BETWEEN of every report) then comes out as 1 row or as one whole bucket,
 * and a nested loop is chosen for a join that returns thousands of rows.
 *
 * What these functions do:
 *
 * 1. One-sided estimate: call core's own estimator with the operands
 *    relabelled to the core type that has the same representation (jdate as
 *    date, jtimestamp as timestamp, jtimestamptz as timestamptz). Core looks
 *    through the relabelling to the column's statistics, and sees the core type
 *    as the type of the variable and of the constant, so it interpolates.
 *    The operator passed along is still ours, so MCV matching uses our own
 *    comparison function.
 *
 * 2. Pairing: core pairs a lower and an upper bound on the same expression
 *    (s = s_hi + s_lo - 1) in clauselist_selectivity, but only for clauses
 *    whose estimator is core's own scalarltsel, scalarlesel, scalargtsel or
 *    scalargesel (compared by function OID), which ours are not. So the
 *    pairing is done here. The estimator of the first upper-bound clause finds
 *    the AND-group that holds it (the relation's restriction list, a nested
 *    AND, or one arm of an OR or the argument of a NOT, which is how
 *    clauselist_selectivity groups clauses too). If the group has a
 *    lower-bound clause on the same expression, whose other operand is a
 *    pseudo-constant, the estimator returns the conditional selectivity
 *    s_range / s_lo. The lower-bound clause keeps its own one-sided estimate,
 *    so the product that clauselist_selectivity forms is s_range, and a lower
 *    bound estimated on its own (as the predicate of a partial index is) stays
 *    correct. Only the first lower and the first upper bound of a group pair;
 *    further bounds stay one-sided and are multiplied in, as independent.
 *
 * Anything unexpected (an operand that is not one of our types, an expression
 * over more than one relation, no pairing partner in the group) falls back to
 * the one-sided estimate, and when even the relabelling is not possible, to
 * core's estimator on the original operands, which is what these operators
 * used before.
 */
#include "postgres.h"

/* GETSTRUCT() lives in htup_details.h, whose inline functions trip -Wextra */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-parameter"
#include "access/htup_details.h"
#pragma GCC diagnostic pop
#include "catalog/pg_type.h"
#include "fmgr.h"
#include "nodes/nodeFuncs.h"
#include "nodes/pathnodes.h"
#include "optimizer/clauses.h"
#include "optimizer/optimizer.h"
#include "utils/fmgrprotos.h"
#include "utils/lsyscache.h"
#include "utils/selfuncs.h"
#include "utils/syscache.h"

typedef enum JselKind
{
	JSEL_LT,
	JSEL_LE,
	JSEL_GT,
	JSEL_GE
} JselKind;

typedef struct JselClause
{
	Oid			opno;
	List	   *args;
	Node	   *var;			/* the non-constant operand, as written */
	Node	   *bound;			/* the pseudo-constant operand, as written */
	JselKind	kind;
	bool		is_lower;		/* var > bound (or >=) */
} JselClause;

PG_FUNCTION_INFO_V1(jdatetime_ltsel);
PG_FUNCTION_INFO_V1(jdatetime_lesel);
PG_FUNCTION_INFO_V1(jdatetime_gtsel);
PG_FUNCTION_INFO_V1(jdatetime_gesel);

static PGFunction
core_estimator(JselKind kind)
{
	switch (kind)
	{
		case JSEL_LT:
			return scalarltsel;
		case JSEL_LE:
			return scalarlesel;
		case JSEL_GT:
			return scalargtsel;
		default:
			return scalargesel;
	}
}

/*
 * The core type whose representation the type has, or InvalidOid when it is
 * not one of ours. A type counts as ours when its name matches and it lives in
 * the schema of this function.
 */
static Oid
core_type_of(Oid typid, Oid ownns)
{
	HeapTuple	tup;
	Form_pg_type typ;
	Oid			result = InvalidOid;

	tup = SearchSysCache1(TYPEOID, ObjectIdGetDatum(typid));
	if (!HeapTupleIsValid(tup))
		return InvalidOid;
	typ = (Form_pg_type) GETSTRUCT(tup);
	if (typ->typnamespace == ownns)
	{
		if (strcmp(NameStr(typ->typname), "jdate") == 0)
			result = DATEOID;
		else if (strcmp(NameStr(typ->typname), "jtimestamp") == 0)
			result = TIMESTAMPOID;
		else if (strcmp(NameStr(typ->typname), "jtimestamptz") == 0)
			result = TIMESTAMPTZOID;
	}
	ReleaseSysCache(tup);
	return result;
}

/* The operand as the core type: a retyped copy for a Const, else a relabel. */
static Node *
relabel_operand(Node *arg, Oid core)
{
	if (IsA(arg, Const))
	{
		Const	   *c = (Const *) copyObject(arg);

		c->consttype = core;
		c->consttypmod = -1;
		return (Node *) c;
	}
	{
		/* makeRelabelType() by hand: makefuncs.h drags in executor headers */
		RelabelType *rt = makeNode(RelabelType);

		rt->arg = (Expr *) arg;
		rt->resulttype = core;
		rt->resulttypmod = -1;
		rt->resultcollid = InvalidOid;
		rt->relabelformat = COERCE_IMPLICIT_CAST;
		rt->location = -1;
		return (Node *) rt;
	}
}

/* The operand list with both operands relabelled, or NIL if it cannot be. */
static List *
relabel_args(List *args, Oid ownns)
{
	Node	   *l,
			   *r;
	Oid			lt,
				rt;

	if (list_length(args) != 2)
		return NIL;
	l = (Node *) linitial(args);
	r = (Node *) lsecond(args);
	lt = core_type_of(exprType(l), ownns);
	rt = core_type_of(exprType(r), ownns);
	if (!OidIsValid(lt) || !OidIsValid(rt))
		return NIL;
	return list_make2(relabel_operand(l, lt), relabel_operand(r, rt));
}

static double
one_sided(PG_FUNCTION_ARGS, JselKind kind, Oid opno, List *args)
{
	PlannerInfo *root = (PlannerInfo *) PG_GETARG_POINTER(0);
	int			varRelid = PG_GETARG_INT32(3);
	List	   *relabelled = relabel_args(args, get_func_namespace(fcinfo->flinfo->fn_oid));

	return DatumGetFloat8(DirectFunctionCall4Coll(core_estimator(kind),
												  PG_GET_COLLATION(),
												  PointerGetDatum(root),
												  ObjectIdGetDatum(opno),
												  PointerGetDatum(relabelled != NIL ? relabelled : args),
												  Int32GetDatum(varRelid)));
}

static Node *
strip_relabel(Node *n)
{
	while (n && IsA(n, RelabelType))
		n = (Node *) ((RelabelType *) n)->arg;
	return n;
}

/*
 * Describe a clause `operand op operand` whose estimator is one of ours and
 * whose operands are an expression over one relation and a pseudo-constant
 * (the shape in which core pairs bounds too). False otherwise.
 */
static bool
describe_clause(Oid opno, List *args, JselClause *out)
{
	FmgrInfo	fi;
	Oid			restrictfn = get_oprrest(opno);
	Node	   *l,
			   *r;
	bool		varonleft;
	bool		is_gt;

	if (!OidIsValid(restrictfn) || list_length(args) != 2)
		return false;
	fmgr_info(restrictfn, &fi);
	if (fi.fn_addr == jdatetime_ltsel)
		out->kind = JSEL_LT;
	else if (fi.fn_addr == jdatetime_lesel)
		out->kind = JSEL_LE;
	else if (fi.fn_addr == jdatetime_gtsel)
		out->kind = JSEL_GT;
	else if (fi.fn_addr == jdatetime_gesel)
		out->kind = JSEL_GE;
	else
		return false;

	l = (Node *) linitial(args);
	r = (Node *) lsecond(args);
	if (is_pseudo_constant_clause(r) && !is_pseudo_constant_clause(l))
	{
		varonleft = true;
		out->var = l;
		out->bound = r;
	}
	else if (is_pseudo_constant_clause(l) && !is_pseudo_constant_clause(r))
	{
		varonleft = false;
		out->var = r;
		out->bound = l;
	}
	else
		return false;

	is_gt = (out->kind == JSEL_GT || out->kind == JSEL_GE);
	out->opno = opno;
	out->args = args;
	out->is_lower = (is_gt == varonleft);
	return true;
}

/* The lower and the upper bound that pair in one AND-group of clauses. */
typedef struct JselGroup
{
	JselClause	lower;
	JselClause	upper;
	bool		have_lower;
	bool		have_upper;
	bool		have_me;		/* the clause being estimated is in the group */
} JselGroup;

static bool scan_group(List *clauses, const JselClause *me, JselGroup *answer);

/*
 * Add the clauses of one AND-group to g. A nested AND joins the group; the
 * arms of an OR and the argument of a NOT are groups of their own, and when
 * one of those holds the clause being estimated, it is the answer (true).
 */
static bool
collect_group(List *clauses, const JselClause *me, JselGroup *g, JselGroup *answer)
{
	ListCell   *lc;

	foreach(lc, clauses)
	{
		Node	   *n = (Node *) lfirst(lc);

		if (n && IsA(n, RestrictInfo))
			n = (Node *) ((RestrictInfo *) n)->clause;
		if (n == NULL)
			continue;
		if (is_opclause(n))
		{
			JselClause	c;

			if (!describe_clause(((OpExpr *) n)->opno, ((OpExpr *) n)->args, &c) ||
				!equal(strip_relabel(c.var), strip_relabel(me->var)))
				continue;
			if (c.is_lower && !g->have_lower)
			{
				g->lower = c;
				g->have_lower = true;
			}
			else if (!c.is_lower && !g->have_upper)
			{
				g->upper = c;
				g->have_upper = true;
			}
			if (c.is_lower == me->is_lower && equal(c.bound, me->bound))
				g->have_me = true;
		}
		else if (IsA(n, BoolExpr))
		{
			BoolExpr   *b = (BoolExpr *) n;
			ListCell   *ac;

			if (b->boolop == AND_EXPR)
			{
				if (collect_group(b->args, me, g, answer))
					return true;
			}
			else
			{
				foreach(ac, b->args)
				{
					if (scan_group(list_make1(lfirst(ac)), me, answer))
						return true;
				}
			}
		}
	}
	return false;
}

/* The AND-group of clauses that holds me; true and *answer if there is one. */
static bool
scan_group(List *clauses, const JselClause *me, JselGroup *answer)
{
	JselGroup	g = {0};

	if (collect_group(clauses, me, &g, answer))
		return true;
	if (!g.have_me)
		return false;
	*answer = g;
	return true;
}

static Datum
jdatetime_sel(PG_FUNCTION_ARGS, JselKind kind)
{
	PlannerInfo *root = (PlannerInfo *) PG_GETARG_POINTER(0);
	Oid			opno = PG_GETARG_OID(1);
	List	   *args = (List *) PG_GETARG_POINTER(2);
	int			varRelid = PG_GETARG_INT32(3);
	double		s1 = one_sided(fcinfo, kind, opno, args);
	JselClause	me;
	JselGroup	g = {0};
	Relids		relids;
	int			varno;
	RelOptInfo *rel;
	double		s_lo,
				range;

	/*
	 * Only an upper bound does anything: it takes the pairing for the whole
	 * range. The lower bound keeps its own one-sided estimate.
	 */
	if (root == NULL || !describe_clause(opno, args, &me) || me.is_lower)
		PG_RETURN_FLOAT8(s1);

	/* the relation the variable belongs to, and its restriction clauses */
	relids = pull_varnos(root, me.var);
	if (!bms_get_singleton_member(relids, &varno) ||
		root->simple_rel_array == NULL ||
		varno <= 0 || varno >= root->simple_rel_array_size)
		PG_RETURN_FLOAT8(s1);
	rel = root->simple_rel_array[varno];
	if (rel == NULL ||
		(rel->reloptkind != RELOPT_BASEREL &&
		 rel->reloptkind != RELOPT_OTHER_MEMBER_REL))
		PG_RETURN_FLOAT8(s1);

	/* only the first upper bound of its group pairs with the first lower bound */
	if (!scan_group(rel->baserestrictinfo, &me, &g) ||
		!g.have_lower || !g.have_upper || !equal(g.upper.bound, me.bound))
		PG_RETURN_FLOAT8(s1);

	s_lo = one_sided(fcinfo, g.lower.kind, g.lower.opno, g.lower.args);
	if (s_lo <= 0.0)
		PG_RETURN_FLOAT8(s1);
	if (s_lo == DEFAULT_INEQ_SEL || s1 == DEFAULT_INEQ_SEL)
		range = DEFAULT_RANGE_INEQ_SEL;
	else
	{
		/* core's own formula, see clauselist_selectivity_ext in clausesel.c */
		range = s1 + s_lo - 1.0 +
			nulltestsel(root, IS_NULL, me.var, varRelid, JOIN_INNER, NULL);
		if (range <= 0.0)
			range = (range < -0.01) ? DEFAULT_RANGE_INEQ_SEL : 1.0e-10;
	}
	if (range > s_lo)
		range = s_lo;
	PG_RETURN_FLOAT8(range / s_lo);
}

Datum
jdatetime_ltsel(PG_FUNCTION_ARGS)
{
	return jdatetime_sel(fcinfo, JSEL_LT);
}

Datum
jdatetime_lesel(PG_FUNCTION_ARGS)
{
	return jdatetime_sel(fcinfo, JSEL_LE);
}

Datum
jdatetime_gtsel(PG_FUNCTION_ARGS)
{
	return jdatetime_sel(fcinfo, JSEL_GT);
}

Datum
jdatetime_gesel(PG_FUNCTION_ARGS)
{
	return jdatetime_sel(fcinfo, JSEL_GE);
}
