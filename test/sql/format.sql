SET timezone = 'Asia/Tehran';
SELECT jdate_format(timestamptz '2024-03-20 00:30:00+03:30') AS tehran_local;
SELECT jdate_format(timestamptz '2024-03-20 00:30:00+03:30', false) AS tehran_date_only;

SET timezone = 'UTC';
SELECT jdate_format(timestamptz '2024-03-20 00:30:00+03:30') AS utc_crosses_to_prior_day;

RESET timezone;
