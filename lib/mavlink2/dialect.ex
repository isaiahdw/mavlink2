defmodule MAVLink2.Dialect do
  @moduledoc """
  A MAVLink dialect: for each message id, the `crc_extra` byte the checksum
  ends with and the payload length the receiver zero-extends to.

  `MAVLink2.Frame` and `MAVLink2.Link` take the dialect as a module. Both
  return `nil` for an id the dialect does not have.

  `target_offsets/1` is optional: for a message with `target_system` or
  `target_component` fields, their byte offsets in the payload, `nil` for a
  field the message lacks. `MAVLink2.Router` uses it; without it, every
  message without a header target is a broadcast.
  """

  @callback crc_extra(msgid :: non_neg_integer()) :: 0..255 | nil
  @callback payload_length(msgid :: non_neg_integer()) :: pos_integer() | nil
  @callback target_offsets(msgid :: non_neg_integer()) ::
              {system :: non_neg_integer() | nil, component :: non_neg_integer() | nil}

  @optional_callbacks target_offsets: 1
end
