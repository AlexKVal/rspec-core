module RSpec
  module Core
    # Each ExampleGroup class and Example instance ...
    #
    # @see Example#metadata
    # @see ExampleGroup.metadata
    class Metadata < Hash

        # @private
      module MetadataHash

        # @private
        # Supports lazy evaluation of some values. Extended by
        # ExampleMetadataHash and GroupMetadataHash, which get mixed in to
        # Metadata for ExampleGroups and Examples (respectively).
        def [](key)
          return super if has_key?(key)
          case key
          when :location
            store(:location, "#{self[:file_path]}:#{self[:line_number]}")
          when :file_path, :line_number
            first_caller_from_outside_rspec =~ /(.+?):(\d+)/
            store(:file_path, $1)
            store(:line_number, $2.to_i)
            super
          when :execution_result
            store(:execution_result, {})
          when :describes, :described_class
            klass = described_class_for(self)
            store(:described_class, klass)
            # TODO (2011-11-07 DC) deprecate :describes as a key
            store(:describes, klass)
          when :full_description
            store(:full_description, full_description_for_self)
          when :description
            store(:description, build_description_from(*self[:description_args]))
          else
            super
          end
        end

      private

        def first_caller_from_outside_rspec
          self[:caller].detect {|l| l !~ /\/lib\/rspec\/core/}
        end

        def described_class_for(m)
          m[:example_group][:described_class]
        end

        def full_description_for_self
          build_description_from(self[:example_group][:full_description], *self[:description_args])
        end

        def build_description_from(*parts)
          parts.map {|p| p.to_s}.inject do |desc, p|
            p =~ /^(#|::|\.)/ ? "#{desc}#{p}" : "#{desc} #{p}"
          end || ""
        end
      end

      # Mixed in to Metadata for an Example (extends MetadataHash) to support
      # lazy evaluation of some values.
      module ExampleMetadataHash
        include MetadataHash
      end

      # Mixed in to Metadata for an ExampleGroup (extends MetadataHash) to
      # support lazy evaluation of some values.
      module GroupMetadataHash
        include MetadataHash

      private

        def described_class_for(*)
          ancestors.each do |g|
            # TODO remove describes
            return g[:describes] if g.has_key?(:describes)
            return g[:described_class] if g.has_key?(:described_class)
          end

          ancestors.reverse.each do |g|
            candidate = g[:description_args].first
            return candidate unless String === candidate || Symbol === candidate
          end

          nil
        end

        def full_description_for_self
          build_description_from(*ancestors.reverse.map {|a| a[:description_args]}.flatten)
        end

        def ancestors
          @ancestors ||= begin
                           groups = [group = self]
                           while group.has_key?(:example_group)
                             groups << group[:example_group]
                             group = group[:example_group]
                           end
                           groups
                         end
        end
      end

      def initialize(parent_group_metadata=nil)
        if parent_group_metadata
          update(parent_group_metadata)
          store(:example_group, {:example_group => parent_group_metadata[:example_group]}.extend(GroupMetadataHash))
        else
          store(:example_group, {}.extend(GroupMetadataHash))
        end

        yield self if block_given?
      end

      # @private
      def for_example_group(*args)
        user_metadata = args.last.is_a?(Hash) ? args.pop : {}
        ensure_valid_keys(user_metadata)

        self[:example_group].store(:description_args, args)
        self[:example_group].store(:caller, user_metadata.delete(:caller) || caller)

        update(user_metadata)
      end

      # @api private
      def for_example(description, user_metadata)
        dup.extend(ExampleMetadataHash).configure_for_example(description, user_metadata)
      end

      # @api private
      def any_apply?(filters)
        filters.any? {|k,v| filter_applies?(k,v)}
      end

      # @api private
      def all_apply?(filters)
        filters.all? {|k,v| filter_applies?(k,v)}
      end

      # @private
      def filter_applies?(key, value, metadata=self)
        case value
        when Hash
          if key == :locations
            file_path     = (self[:example_group] || {})[:file_path]
            expanded_path = file_path && File.expand_path( file_path )
            if expanded_path && line_numbers = value[expanded_path]
              filter_applies?(:line_numbers, line_numbers)
            else
              true
            end
          else
            value.all? { |k, v| filter_applies?(k, v, metadata[key]) }
          end
        when Regexp
          metadata[key] =~ value
        when Proc
          if value.arity == 2
            # Pass the metadata hash to allow the proc to check if it even has the key.
            # This is necessary for the implicit :if exclusion filter:
            #   {            } # => run the example
            #   { :if => nil } # => exclude the example
            # The value of metadata[:if] is the same in these two cases but
            # they need to be treated differently.
            value.call(metadata[key], metadata) rescue false
          else
            value.call(metadata[key]) rescue false
          end
        when String
          metadata[key].to_s == value.to_s
        when Enumerable
          if key == :line_numbers
            preceding_declaration_lines = value.map{|v| world.preceding_declaration_line(v)}
            !(relevant_line_numbers(metadata) & preceding_declaration_lines).empty?
          else
            metadata[key] == value
          end
        else
          metadata[key].to_s == value.to_s
        end
      end

    protected

      def configure_for_example(description, user_metadata)
        store(:description_args, [description])
        store(:caller, user_metadata.delete(:caller) || caller)
        update(user_metadata)
      end

    private

      RESERVED_KEYS = [
        :description_args,
        :description,
        :example_group,
        :execution_result,
        :file_path,
        :full_description,
        :line_number,
        :location
      ]

      def ensure_valid_keys(user_metadata)
        RESERVED_KEYS.each do |key|
          if user_metadata.has_key?(key)
            raise <<-EOM
#{"*"*50}
:#{key} is not allowed

RSpec reserves some hash keys for its own internal use,
including :#{key}, which is used on:

  #{caller(0)[4]}.

Here are all of RSpec's reserved hash keys:

  #{RESERVED_KEYS.join("\n  ")}
#{"*"*50}
EOM
          end
        end
      end

      def world
        RSpec.world
      end

      def relevant_line_numbers(metadata)
        line_numbers = [metadata[:line_number]]
        if metadata[:example_group]
          line_numbers + relevant_line_numbers(metadata[:example_group])
        else
          line_numbers
        end
      end

    end
  end
end
