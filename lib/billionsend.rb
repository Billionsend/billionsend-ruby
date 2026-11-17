# frozen_string_literal: true

require_relative "billionsend/version"
require_relative "billionsend/errors"
require_relative "billionsend/transport"
require_relative "billionsend/pagination"
require_relative "billionsend/webhooks"
require_relative "billionsend/streaming"
require_relative "billionsend/resources"
require_relative "billionsend/client"

# The BillionSend API: sending, receiving, contacts, broadcasts and agent inboxes.
#
#   require "billionsend"
#
#   client = BillionSend::Client.new # reads BILLIONSEND_API_KEY
#   client.emails.send({ from: "Acme <hello@acme.com>", to: ["user@example.com"],
#                        subject: "Hello", text: "It works." })
module BillionSend
end
