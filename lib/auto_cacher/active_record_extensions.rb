# frozen_string_literal: true

module AutoCacher
  module ActiveRecordExtensions
    extend ActiveSupport::Concern

    included do
      class_attribute :auto_cacher_dedicated_to_association, instance_accessor: false, default: nil
      class_attribute :auto_cacher_dedicated_association, instance_accessor: false, default: nil
      class_attribute :auto_cacher_list, instance_accessor: false, default: []
    end

    class_methods do
      # DEPRECATED: define AutoCacher::Cacher classes in app/cachers, instead
      def auto_cacher_field(field_name, options = {})
        cacher = AutoCacher::Cacher.new(**options.merge(klass: self, field: field_name))
        AutoCacher.register_cacher cacher

        ::HallMonitor.register_watcher(
          ::HallMonitor::Watcher.new(
            field_map: cacher.watching,
            operations: cacher.operations,
            callback: ->(data_change) do
              cacher.call(data_change)
            end
          )
        )
      end

      def has_dedicated_auto_cacher(association_name, *args, **kwargs)
        kwargs[:dependent] = :destroy unless kwargs.key?(:dependent)
        # require inverse_of
        unless kwargs.key?(:inverse_of)
          raise ArgumentError, "inverse_of is required for has_dedicated_auto_cacher"
        end
        self.auto_cacher_dedicated_association = association_name
        has_one association_name, *args, **kwargs
        auto_cacher_list << association_name

        class_eval do
          reflection = reflect_on_association(association_name)
          dedicated_cacher_klass = reflection.klass
          AutoCacher.register_dedicated_auto_cacher_model(dedicated_cacher_klass)

          # Accessor that will find or create the dedicated cache model record.
          # Structured to be safe to call by multiple threads simultaneously.
          # Makes multiple attempts to create/find the record as part of handling race conditions.
          define_method(:find_or_create_dedicated_auto_cacher_instance) do
            instance_variable_get("@#{association_name}") || begin
              dedicated_cacher_instance = nil
              max_retries = 3
              retry_count = 0
              backoff_time = 0.1 # seconds

              begin
                dedicated_cacher_instance = find_dedicated_auto_cacher_instance
                dedicated_cacher_instance ||= create_dedicated_auto_cacher_instance
              rescue => e
                if retry_count < max_retries
                  retry_count += 1
                  # Skip sleep for uniqueness violations. Record likely exists, retry will find it faster this way.
                  sleep(backoff_time * retry_count) unless e.is_a?(ActiveRecord::RecordNotUnique)
                  retry
                else
                  Rails.logger.error("Failed to find or create #{association_name} after #{max_retries} attempts: #{e.message}")
                  raise e
                end
              end

              set_dedicated_auto_cacher_instance(dedicated_cacher_instance)
            end
          end

          # alias for convenience
          define_method(association_name) do
            find_or_create_dedicated_auto_cacher_instance
          end

          private

          define_method(:find_dedicated_auto_cacher_instance) do
            dedicated_cacher_klass.find_by(dedicated_auto_cacher_instance_condition)
          end

          define_method(:create_dedicated_auto_cacher_instance) do
            dedicated_cacher_instance = dedicated_cacher_klass.create!(dedicated_auto_cacher_instance_condition)
            AutoCacher.callbacks_for(:after_dedicated_model_creation).each do |callback|
              callback.call(dedicated_cacher_instance)
            end
            dedicated_cacher_instance
          end

          define_method(:dedicated_auto_cacher_instance_condition) do
            {reflection.inverse_of.name => self}
          end

          define_method(:set_dedicated_auto_cacher_instance) do |dedicated_cacher_instance|
            instance_variable_set("@#{association_name}", dedicated_cacher_instance)
          end
        end
      end

      def auto_cacher_dedicated_to(association_name, *args, **kwargs)
        self.auto_cacher_dedicated_to_association = association_name
        belongs_to association_name, *args, **kwargs
        AutoCacher.register_dedicated_auto_cacher_model(self)
      end

      def is_dedicated_auto_cacher?
        auto_cacher_dedicated_to_association.present?
      end

      def has_dedicated_auto_cacher?
        auto_cacher_dedicated_association.present?
      end

      def dedicated_auto_cacher_klass
        return nil unless has_dedicated_auto_cacher?
        association = reflect_on_association(auto_cacher_dedicated_association)
        association.klass
      end

      def auto_cacher_dedicated_to_klass
        return nil unless is_dedicated_auto_cacher?
        association = reflect_on_association(auto_cacher_dedicated_to_association)
        association.klass
      end

      def auto_cacher_fields
        AutoCacher.cachers_for(self).map { |cacher| [cacher.field.to_sym, cacher] }.to_h
      end
    end

    # for finding the dedicated AutoCacher models on primary models
    def dedicated_auto_cacher
      return nil unless self.class.has_dedicated_auto_cacher?
      send(self.class.auto_cacher_dedicated_association)
    end

    # for finding the primary models on dedicated AutoCacher models
    def auto_cacher_dedicated_to
      return nil unless self.class.is_dedicated_auto_cacher?
      send(self.class.auto_cacher_dedicated_to_association)
    end

    def auto_cacher_populate(field_list = nil)
      field_list ||= self.class.auto_cacher_fields.keys
      field_list = Array(field_list).map(&:to_sym) & self.class.auto_cacher_fields.keys
      field_list.each do |field_name|
        value = auto_cacher_calculate(field_name)
        send("#{field_name}=", value)
      end
    end

    def auto_cacher_for(field_name)
      self.class.auto_cacher_fields[field_name.to_sym]
    end

    def auto_cacher_calculate(field_name)
      cacher = auto_cacher_for(field_name)
      cacher.calculation.call(self)
    end

    def auto_cacher_populate_and_save!
      auto_cacher_populate
      save!
    end
  end
end 