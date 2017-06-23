module Chewy
  class Type
    module Import
      # This class performs the import routine for the options and objects given.
      #
      # 0. Create target and journal indexes if needed.
      # 1. Iterate over all the passed objects in batches.
      # 2. For each batch {#process} method is called:
      #   * creates a bulk request body;
      #   * appends journal entries for the current batch to the request body;
      #   * prepends a leftovers bulk to the request body, which is calculated
      #     basing on the previous iteration errors;
      #   * performs the bulk request;
      #   * composes new leftovers bulk for the next iteration basing on the response errors if `update_failover` is true;
      #   * appends the rest of unfixable errors to the instance level errors array.
      # 4. Perform the request for the last leftovers bulk if present using {#process_leftovers}.
      # 3. Return the result errors array.
      #
      # At the moment, it tries to restore only from the partial document update errors in cases
      # when the document doesn't exist only if `update_failover` option is true. In order to
      # restore, it indexes such an objects completely on the next iteration.
      #
      # @see Chewy::Type::Import::ClassMethods#import
      class Routine
        BULK_OPTIONS = %i[
          suffix bulk_size
          refresh timeout fields pipeline
          consistency replication
          wait_for_active_shards routing _source _source_exclude _source_include
        ].freeze

        DEFAULT_OPTIONS = {
          refresh: true,
          update_fields: [],
          update_failover: true
        }.freeze

        attr_reader :options, :errors

        # Basically, processes passed options, extracting bulk request specific options.
        # @param type [Chewy::Type] chewy type
        # @param options [Hash] import options, see {Chewy::Type::Import::ClassMethods#import}
        def initialize(type, **options)
          @type = type
          @options = options
          @options.reverse_merge!(@type._default_import_options)
          @options.reverse_merge!(journal: Chewy.configuration[:journal])
          @options.reverse_merge!(DEFAULT_OPTIONS)
          @bulk_options = @options.extract!(*BULK_OPTIONS)
          @errors = []
          @leftovers = []
        end

        # Creates the journal index and the type corresponding index if necessary.
        # @return [Object] whatever
        def create_indexes!
          Chewy::Journal.create if @options[:journal]
          return if Chewy.configuration[:skip_index_creation_on_import]
          @type.index.create!(@bulk_options.slice(:suffix)) unless @type.index.exists?
        end

        # The main process method. Converts passed objects to thr bulk request body,
        # appends journal entires, performs this request and handles errors performing
        # failover procedures if applicable.
        #
        # @param index [Array<Object>] any acceptable objects for indexing
        # @param delete [Array<Object>] any acceptable objects for deleting
        # @return [true, false] the result of the request, true if no errors
        def process(index: [], delete: [])
          bulk_builder = BulkBuilder.new(@type, index: index, delete: delete, fields: @options[:update_fields])
          bulk_body = bulk_builder.bulk_body

          bulk_body.concat(journal_bulk(index: index, delete: delete))
          bulk_body.unshift(*flush_leftovers)

          response = bulk.perform(bulk_body)
          Chewy.wait_for_status

          @leftovers = extract_leftovers(response, bulk_builder.index_objects_by_id)

          @errors.concat(response)
          response.blank?
        end

        # Processes the last leftovers bulk if any.
        #
        # @return [true, false] the result of the request, true if no errors
        def process_leftovers
          response = bulk.perform(flush_leftovers)
          Chewy.wait_for_status
          @errors.concat(response)
          response.blank?
        end

      private

        def journal_bulk(action_objects)
          return [] unless @options[:journal]
          journal = Chewy::Journal.new(@type)
          journal.add(action_objects)
          journal.bulk_body
        end

        def flush_leftovers
          leftovers = @leftovers
          @leftovers = []
          leftovers
        end

        def extract_leftovers(errors, index_objects_by_id)
          return [] unless @options[:update_fields].present? && @options[:update_failover] && errors.present?

          failed_partial_updates = errors.select do |item|
            item.keys.first == 'update' && item.values.first['error']['type'] == 'document_missing_exception'
          end
          failed_ids_hash = failed_partial_updates.index_by { |item| item.values.first['_id'].to_s }
          failed_ids_for_reimport = failed_ids_hash.keys & index_objects_by_id.keys
          errors_to_cleanup = failed_ids_hash.values_at(*failed_ids_for_reimport)
          errors_to_cleanup.each { |error| errors.delete(error) }

          failed_objects = index_objects_by_id.values_at(*failed_ids_for_reimport)
          BulkBuilder.new(@type, index: failed_objects).bulk_body
        end

        def bulk
          @bulk ||= BulkRequest.new(@type, **@bulk_options)
        end
      end
    end
  end
end