defmodule MAVLink2.CancelDialect do
  @moduledoc false
  use MAVLink2.Dialect.XML, file: "test/fixtures/command_cancel.xml"
end
