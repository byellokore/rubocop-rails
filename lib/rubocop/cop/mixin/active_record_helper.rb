# frozen_string_literal: true

module RuboCop
  module Cop
    # A mixin to extend cops for Active Record features
    module ActiveRecordHelper
      extend NodePattern::Macros

      WHERE_METHODS = %i[where rewhere].freeze

      def_node_matcher :active_record?, <<~PATTERN
        {
          (const nil? :ApplicationRecord)
          (const (const nil? :ActiveRecord) :Base)
        }
      PATTERN

      def_node_search :find_set_table_name, <<~PATTERN
        (send self :table_name= {str sym})
      PATTERN

      def_node_search :find_belongs_to, <<~PATTERN
        (send nil? :belongs_to {str sym} ...)
      PATTERN

      def inherit_active_record_base?(node)
        node.each_ancestor(:class).any? { |class_node| active_record?(class_node.parent_class) }
      end

      def external_dependency_checksum
        return @external_dependency_checksum if defined?(@external_dependency_checksum)

        schema_path = RuboCop::Rails::SchemaLoader.db_schema_path
        return nil if schema_path.nil?

        schema_code = File.read(schema_path)

        @external_dependency_checksum ||= Digest::SHA1.hexdigest(schema_code)
      end

      def schema
        RuboCop::Rails::SchemaLoader.load(target_ruby_version)
      end

      def table_name(class_node)
        table_name = find_set_table_name(class_node).to_a.last&.first_argument
        return table_name.value.to_s if table_name

        class_nodes = class_node.defined_module.each_node
        namespaces = class_node.each_ancestor(:class, :module).map(&:identifier)
        table_prefix, table_suffix = mount_table_name(class_node)

        [*class_nodes, *namespaces]
          .reverse
          .map { |node| node.children[1] }.join('_')
          .tableize
          .yield_self { |base_table_name| table_prefix + base_table_name + table_suffix }
      end

      # Resolves the table name with prefixes and suffixes
      # if a prefix or suffix is found it will return the value
      # otherwise it will return ''
      def mount_table_name(class_node)
        table_name_parts = []
        class_node.each_descendant do |descendant|
          next unless descendant.instance_of?(RuboCop::AST::SendNode)

          send_node = RuboCop::NodePattern.new('(:send _ $...)').match(descendant)
          if send_node && /table_name_(prefix|suffix)/.match(send_node[0])
            table_name_parts << { send_node[0] => send_node[1].children&.first }
          end
        end

        table_prefix = mount_prefix(table_name_parts)
        table_suffix = mount_suffix(table_name_parts)

        [table_prefix, table_suffix]
      end

      def mount_prefix(name_part)
        name_part.select { |part| part[:table_name_prefix=] }
                 .yield_self { |arr_prefix| arr_prefix.empty? ? '' : "#{arr_prefix.first[:table_name_prefix=]}_" }
      end

      def mount_suffix(name_part)
        name_part.select { |part| part[:table_name_suffix=] }
                 .yield_self { |arr_suffix| arr_suffix.empty? ? '' : "_#{arr_suffix.first[:table_name_suffix=]}" }
      end

      # Resolve relation into column name.
      # It just returns column_name if the column exists.
      # Or it tries to resolve column_name as a relation.
      # Returns an array of column names if the relation is polymorphic.
      # It returns `nil` if it can't resolve.
      #
      # @param name [String]
      # @param class_node [RuboCop::AST::Node]
      # @param table [RuboCop::Rails::SchemaLoader::Table]
      # @return [Array, String, nil]
      def resolve_relation_into_column(name:, class_node:, table:)
        return unless table
        return name if table.with_column?(name: name)

        find_belongs_to(class_node) do |belongs_to|
          next unless belongs_to.first_argument.value.to_s == name

          fk = foreign_key_of(belongs_to) || "#{name}_id"
          next unless table.with_column?(name: fk)

          return polymorphic?(belongs_to) ? [fk, "#{name}_type"] : fk
        end
        nil
      end

      def foreign_key_of(belongs_to)
        options = belongs_to.last_argument
        return unless options.hash_type?

        options.each_pair.find do |pair|
          next unless pair.key.sym_type? && pair.key.value == :foreign_key
          next unless pair.value.sym_type? || pair.value.str_type?

          break pair.value.value.to_s
        end
      end

      def polymorphic?(belongs_to)
        options = belongs_to.last_argument
        return false unless options.hash_type?

        options.each_pair.any? do |pair|
          pair.key.sym_type? && pair.key.value == :polymorphic && pair.value.true_type?
        end
      end

      def in_where?(node)
        send_node = node.each_ancestor(:send).first
        send_node && WHERE_METHODS.include?(send_node.method_name)
      end
    end
  end
end
