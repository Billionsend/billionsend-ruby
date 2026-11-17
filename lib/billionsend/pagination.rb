# frozen_string_literal: true

module BillionSend
  # Iterates over every item of a cursor-paginated list.
  #
  # Lists are newest first: +after+ takes the last id of a page and pages
  # toward older items, +before+ takes the first id and pages toward newer ones.
  module Pagination
    # An Enumerator over every item, calling +fetch.call(after, before)+ for each
    # page (a Hash with "data" and "has_more").
    def self.each_item(after:, before:, &fetch)
      Enumerator.new do |out|
        backward = !before.nil? && after.nil?
        loop do
          page = fetch.call(after, before)
          items = page["data"] || []
          items.each { |item| out << item }
          break if !page["has_more"] || items.empty?

          if backward
            before = items.first["id"].to_s
          else
            after = items.last["id"].to_s
          end
        end
      end
    end
  end
end
