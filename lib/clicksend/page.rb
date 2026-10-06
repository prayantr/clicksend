# frozen_string_literal: true

module Clicksend
  # One page of a paginated ClickSend list.
  #
  # ClickSend paginates with +page+ and +limit+ query parameters (limit 15..100,
  # default 15) and returns +total+, +per_page+, +current_page+ and +last_page+
  # alongside the items.
  #
  # A Page is Enumerable over *its own* items. To walk every page, fetching
  # further pages lazily as needed, use #auto_paging_each:
  #
  #   client.sms.receipts.auto_paging_each { |receipt| ... }
  #   client.sms.receipts.auto_paging_each.first(250)
  class Page
    include Enumerable

    LIMITS = (15..100)

    attr_reader :items, :total, :per_page, :current_page, :last_page

    # Fetches one page.
    # @api private Use Client#paginate or a resource method.
    #
    # @yieldparam item [Hash] a raw item, to be converted into a model
    def self.fetch(client, path, query: {}, page: nil, limit: nil, operation: nil, &build_item)
      if page && !(page.is_a?(Integer) && page.positive?)
        raise ArgumentError, "page must be a positive Integer"
      end
      if limit && !(limit.is_a?(Integer) && LIMITS.cover?(limit))
        raise ArgumentError, "limit must be an Integer between #{LIMITS.min} and #{LIMITS.max} (ClickSend's documented range)"
      end
      raise ArgumentError, "query must be a Hash" unless query.nil? || query.is_a?(Hash)

      query = (query || {}).transform_keys(&:to_s)
      response = client.request(:get, path, query: query.merge("page" => page, "limit" => limit).compact, operation: operation)
      fetch_page = ->(number) { fetch(client, path, query: query, page: number, limit: limit, operation: operation, &build_item) }
      from_response(response, fetch_page, &build_item)
    rescue MalformedResponseError => e
      e.request ||= response&.request
      raise
    end

    def self.from_response(response, fetch_page, &build_item)
      data = response.data
      unless data.is_a?(Hash) && data["data"].is_a?(Array)
        raise MalformedResponseError.new("Expected a paginated response with a data list", http_status: response.http_status, body: response.body)
      end

      numbers = %w[total per_page current_page last_page].to_h do |key|
        value = Integer(data[key], exception: false) if data[key].is_a?(Integer) || data[key].is_a?(String)
        raise MalformedResponseError.new("Paginated response is missing #{key}", http_status: response.http_status, body: response.body) if value.nil?
        # Pages are numbered from 1 (the page parameter defaults to 1); counts can be 0.
        if value < ((key == "current_page") ? 1 : 0)
          raise MalformedResponseError.new("Paginated response has an invalid #{key}: #{value}", http_status: response.http_status, body: response.body)
        end

        [key.to_sym, value]
      end
      items = data["data"].map { |item| build_item ? build_item.call(item) : item }
      new(items: items.freeze, **numbers, fetch_page: fetch_page)
    end
    private_class_method :from_response

    def initialize(items:, total:, per_page:, current_page:, last_page:, fetch_page:)
      @items = items
      @total = total
      @per_page = per_page
      @current_page = current_page
      @last_page = last_page
      @fetch_page = fetch_page
      freeze
    end

    def each(&)
      items.each(&)
      self
    end

    def size
      items.size
    end

    def empty?
      items.empty?
    end

    def next_page?
      current_page < last_page && !items.empty?
    end

    # @return [Page, nil] the following page, fetched from ClickSend, or nil on the last page
    def next_page
      @fetch_page.call(current_page + 1) if next_page?
    end

    # Yields every item on this and all following pages, fetching pages as
    # needed. Without a block, returns a lazy-friendly Enumerator.
    def auto_paging_each(&block)
      return enum_for(:auto_paging_each) unless block

      page = self
      loop do
        page.each(&block)
        following = page.next_page
        # Stop if the API ever fails to advance, rather than looping forever.
        break if following.nil? || following.current_page <= page.current_page

        page = following
      end
      self
    end

    def inspect
      "#<#{self.class.name} current_page=#{current_page} last_page=#{last_page} total=#{total} items=#{items.size}>"
    end
  end
end
