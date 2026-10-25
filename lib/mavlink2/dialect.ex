defmodule MAVLink2.Dialect do
  @moduledoc """
  A MAVLink dialect: for each message id, the `crc_extra` byte the checksum
  ends with and the payload length the receiver zero-extends to.

  `MAVLink2.Frame` and `MAVLink2.Link` take the dialect as a module. Both
  return `nil` for an id the dialect does not have.
  """

  @callback crc_extra(msgid :: non_neg_integer()) :: 0..255 | nil
  @callback payload_length(msgid :: non_neg_integer()) :: pos_integer() | nil
end
