defmodule EpicLoop.SessionTest do
  use ExUnit.Case, async: true
  alias EpicLoop.{Integration, Session}

  @herdr_name ~r/^[a-z][a-z0-9_-]{0,31}$/

  test "an id that fits is used as is, sanitized" do
    assert Session.name("w-", "acme-u33.2") == "w-acme-u33-2"
    assert Session.name("epic-", "Acme-U33") == "epic-acme-u33"
  end

  test "sibling tickets of a long epic id get distinct names that keep the ticket suffix" do
    a = Session.name("w-", "acme-mock-arithmetic-chain-qbcc.3")
    b = Session.name("w-", "acme-mock-arithmetic-chain-qbcc.4")
    assert a =~ @herdr_name
    assert b =~ @herdr_name
    assert a != b
    assert String.ends_with?(a, "arithmetic-chain-qbcc-3")
    assert String.ends_with?(b, "arithmetic-chain-qbcc-4")
  end

  test "long ids that differ only far from the tail still get different names" do
    a = Session.name("w-", "aaaa-xxxxxxxxxxxxxxxxxxxxxxxxxxxx.1")
    b = Session.name("w-", "bbbb-xxxxxxxxxxxxxxxxxxxxxxxxxxxx.1")
    assert a != b
    assert a =~ @herdr_name
  end

  test "the name is deterministic, so a restarted loop finds its live agent again" do
    assert Session.name("w-", "acme-mock-arithmetic-chain-qbcc.3") == Session.name("w-", "acme-mock-arithmetic-chain-qbcc.3")
  end

  test "the epic session follows the same rule" do
    n = Integration.session_name("acme-mock-arithmetic-chain-qbcc")
    assert n =~ @herdr_name
    assert String.starts_with?(n, "epic-")
    assert String.ends_with?(n, "-qbcc")
  end
end
