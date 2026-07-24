# frozen_string_literal: true

module SqliteSearch
  module Sql
    module_function

    # Build "CASE <pk_sql> WHEN <id> THEN <value> ... END" from an id => value
    # map, quoting each id and value through the connection. Used to carry
    # per-row values computed in Ruby (KNN order, distances, fused scores) into
    # the SQL as an ORDER expression or a selected column.
    def id_case(pk_sql, values, connection)
      whens = values.map { |id, value| "WHEN #{connection.quote(id)} THEN #{connection.quote(value)}" }.join(" ")
      "CASE #{pk_sql} #{whens} END"
    end
  end
end
