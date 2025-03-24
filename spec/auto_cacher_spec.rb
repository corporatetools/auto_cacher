require "rails_helper"

# rubocop:disable Lint/ConstantDefinitionInBlock

module AutoCacherTest
  class DummyRecord < ActiveRecord::Base
    self.table_name = "auto_cacher_dummies"
  end

  class DummyRecord::CachedValueCacher < AutoCacher::Cacher
    configuration(
      watching: {"dummy_records" => ["base"]},
      calculation: ->(record) { record.base * 2 },
      records_to_update: ->(_data_change) { [] } # Not used in these tests.
    )
  end
end

RSpec.describe AutoCacher do
  # TODO: Split these tests into unit and integration tests
  # Unit tests should not require database access and should test:
  # - Configuration validation
  # - Cacher registration
  # - Callback registration and execution
  # - Change queue building logic
  #
  # Integration tests should be in a separate file and test:
  # - Actual database operations
  # - Real record updates
  # - End-to-end caching functionality

  module TestTable
    class TestCacher < AutoCacher::Cacher
      configuration(
        watching: {"test_table" => ["test_field"]},
        calculation: ->(record) { 42 },
        records_to_update: ->(_data_change) { [] }
      )
    end
  end

  describe ".register_cacher" do
    before do
      # Save current cachers to restore later
      @saved_cachers = AutoCacher.registered_cachers.dup
      AutoCacher.instance_variable_set(:@registered_cachers, [])
    end

    after do
      # Restore original cachers
      AutoCacher.instance_variable_set(:@registered_cachers, @saved_cachers)
    end

    it "registers a cacher class" do
      expect {
        AutoCacher.register_cacher(TestTable::TestCacher)
      }.to change { AutoCacher.registered_cachers.count }.by(1)
    end

    it "registers a cacher instance" do
      expect {
        AutoCacher.register_cacher(TestTable::TestCacher.new)
      }.to change { AutoCacher.registered_cachers.count }.by(1)
    end

    it "prevents duplicate cachers" do
      cacher = TestTable::TestCacher.new
      AutoCacher.register_cacher(cacher)

      expect {
        AutoCacher.register_cacher(cacher)
      }.not_to change { AutoCacher.registered_cachers.count }
    end
  end

  describe ".callbacks_for" do
    before do
      # Save current callbacks to restore later
      @saved_callbacks = AutoCacher.callbacks_for(:after_every_recalculation).dup
      AutoCacher.instance_variable_set(:@callbacks_for_after_every_recalculation, [])
    end

    after do
      # Restore original callbacks
      AutoCacher.instance_variable_set(:@callbacks_for_after_every_recalculation, @saved_callbacks)
    end

    it "registers and executes callbacks" do
      callback_executed = false
      AutoCacher.after_every_recalculation do |_details|
        callback_executed = true
      end

      # Manually trigger callbacks
      AutoCacher.callbacks_for(:after_every_recalculation).each do |callback|
        callback.call({})
      end

      expect(callback_executed).to be true
    end
  end

  describe ".cachers_for_table" do
    before do
      @saved_cachers = AutoCacher.registered_cachers.dup
      AutoCacher.instance_variable_set(:@registered_cachers, [])
    end

    after do
      AutoCacher.instance_variable_set(:@registered_cachers, @saved_cachers)
    end

    it "finds cachers for a specific table" do
      AutoCacher.register_cacher(TestTable::TestCacher)
      expect(AutoCacher.cachers_for_table("test_tables").size).to eq(1)
      expect(AutoCacher.cachers_for_table("other_table")).to be_empty
    end
  end

  # Skip database-dependent tests for now
  describe "database operations", skip: "Database tests need to be moved to integration tests" do
    describe ".build_changes_queue" do
      it "builds the changes queue with the correct differences"
    end

    describe ".recalculate" do
      it "updates the record's cached_value based on the calculation"
      it "triggers callbacks when changes occur"
      it "leaves records unchanged if the calculation matches the current value"
    end
  end
end

# rubocop:enable Lint/ConstantDefinitionInBlock 