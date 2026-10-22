-- Test-only helpers, created by the test cluster's superuser in schema test_support.
-- They exist only in the disposable test database.
\set ON_ERROR_STOP 1

CREATE SCHEMA test_support;
GRANT USAGE ON SCHEMA test_support TO PUBLIC;

-- Runs p_sql in a subtransaction. PASS only if it is rejected with an error matching p_pattern.
CREATE FUNCTION test_support.expect_error(p_label text, p_sql text, p_pattern text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_failed boolean := false;
  v_msg    text;
  v_state  text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
    v_msg := SQLERRM;
    v_state := SQLSTATE;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL [%]: statement was accepted but should have been rejected', p_label;
  END IF;
  IF v_msg !~* p_pattern THEN
    RAISE EXCEPTION 'FAIL [%]: rejected with an unexpected error (%): %', p_label, v_state, v_msg;
  END IF;
  RAISE NOTICE 'PASS [%] rejected (%): %', p_label, v_state, v_msg;
END;
$$;

CREATE FUNCTION test_support.ok(p_label text, p_cond boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [%]: condition is %', p_label, coalesce(p_cond::text, 'NULL');
  END IF;
  RAISE NOTICE 'PASS [%]', p_label;
END;
$$;

-- Id lookups, so test statements can stay inside quoted strings.
CREATE FUNCTION test_support.gid(p_order bigint) RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT id FROM us_booking.fulfilment_group WHERE group_key = 'oms:' || p_order || ':g1' $$;
CREATE FUNCTION test_support.pid(p_order bigint, p_no integer) RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT id FROM us_booking.parcel WHERE fulfilment_group_id = test_support.gid(p_order) AND parcel_no = p_no $$;
CREATE FUNCTION test_support.aid(p_order bigint, p_no integer, p_gen integer) RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT id FROM us_booking.booking_attempt WHERE parcel_id = test_support.pid(p_order, p_no) AND attempt_generation = p_gen $$;
