# frozen_string_literal: true

class AccountSearchService < BaseService
  attr_reader :query, :limit, :offset, :options, :account

  def call(query, account = nil, options = {})
    @query   = query.strip.gsub(/\A@/, '')
    @limit   = options[:limit].to_i
    @offset  = options[:offset].to_i
    @options = options
    @account = account

    search_service_results.compact.uniq
  end

  private

  def search_service_results
    return [] if query.blank? || limit < 1

    [exact_match] + search_results
  end

  def exact_match
    return unless offset.zero? && username_complete?

    return @exact_match if defined?(@exact_match)

    @exact_match = begin
      if options[:resolve]
        ResolveAccountService.new.call(query)
      elsif domain_is_local?
        Account.find_local(query_username)
      else
        Account.find_remote(query_username, query_domain)
      end
    end
  end

  def search_results
    return [] if limit_for_non_exact_results.zero?

    @search_results ||= begin
      if Chewy.enabled?
        from_elasticsearch
      else
        from_database
      end
    end
  end

  def from_database
    if account
      advanced_search_results
    else
      simple_search_results
    end
  end

  def advanced_search_results
    Account.advanced_search_for(terms_for_query, account, limit_for_non_exact_results, options[:following], offset)
  end

  def simple_search_results
    Account.search_for(terms_for_query, limit_for_non_exact_results, offset)
  end

  def from_elasticsearch
    must_clauses   = [{ multi_match: { query: terms_for_query, fields: %w(acct display_name), type: 'best_fields' } }]
    should_clauses = []

    if account
      return [] if options[:following] && following_ids.empty?

      if options[:following]
        must_clauses << { terms: { id: following_ids } }
      elsif following_ids.any?
        should_clauses << { terms: { id: following_ids, boost: 2 } }
      end
    end

    query     = { bool: { must: must_clauses, should: should_clauses } }
    functions = [reputation_score_function, followers_score_function, time_distance_function]

    records = AccountsIndex.query(function_score: { query: query, functions: functions, score_mode: 'avg' })
                           .limit(limit_for_non_exact_results)
                           .offset(offset)
                           .objects
                           .compact

    ActiveRecord::Associations::Preloader.new.preload(records, :account_stat)

    records
  end

  def reputation_score_function
    {
      script_score: {
        script: {
          source: "doc['followers_count'].value / (doc['followers_count'].value + doc['following_count'].value + 1)",
        },
      },

      weight: 0.5,
    }
  end

  def followers_score_function
    {
      script_score: {
        script: {
          source: "Math.log(2 + doc['followers_count'].value) / (Math.log(2 + doc['followers_count'].value) + 1)",
        },
      },

      weight: 0.5,
    }
  end

  def time_distance_function
    {
      gauss: {
        last_status_at: {
          scale: '3d',
          offset: '1d',
          decay: 0.3,
        },
      },

      weight: 2,
    }
  end

  def following_ids
    @following_ids ||= account.active_relationships.pluck(:target_account_id)
  end

  def limit_for_non_exact_results
    if exact_match?
      limit - 1
    else
      limit
    end
  end

  def terms_for_query
    if domain_is_local?
      query_username
    else
      query
    end
  end

  def split_query_string
    @split_query_string ||= query.split('@')
  end

  def query_username
    @query_username ||= split_query_string.first || ''
  end

  def query_domain
    @query_domain ||= query_without_split? ? nil : split_query_string.last
  end

  def query_without_split?
    split_query_string.size == 1
  end

  def domain_is_local?
    @domain_is_local ||= TagManager.instance.local_domain?(query_domain)
  end

  def exact_match?
    exact_match.present?
  end

  def username_complete?
    query.include?('@') && "@#{query}" =~ Account::MENTION_RE
  end
end
