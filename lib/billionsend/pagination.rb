# frozen_string_literal: true

module BillionSend
  # Iterates over every item of a cursor-paginated list.
  #
  # Lists are newest first: +after+ takes the last id of a page and pages
  # toward older items, +before+ takes the first id and pages toward newer ones.
  #
  # A page without a data array raises {Error} ("application_error", no status)
  # at once; a page that has more but whose item to continue from has no id
  # hands out its items first, then raises.
  module Pagination
    # An Enumerator over every item, calling +fetch.call(after, before)+ for each
    # page (a Hash with "data" and "has_more").
    def self.each_item(after:, before:, &fetch)
      Enumerator.new do |out|
        backward = !before.nil? && after.nil?
        loop do
          page = fetch.call(after, before)
          items = page.is_a?(Hash) ? page["data"] : nil
          raise Error, "The list page has no data array" unless items.is_a?(Array)

          items.each { |item| out << item }
          break if page["has_more"] != true || items.empty?

          cursor = backward ? items.first : items.last
          id = cursor.is_a?(Hash) ? cursor["id"] : nil
          raise Error, "The last item of the list page has no id to continue from" unless id.is_a?(String) && !id.empty?

          if backward
            before = id
          else
            after = id
          end
        end
      end
    end
  end
end
