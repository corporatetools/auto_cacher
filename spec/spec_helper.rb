require "active_support"
require "active_record"
require "hall_monitor"

# Load the auto_cacher gem
require_relative "../lib/auto_cacher"

# Configure Rails test environment
ENV["RAILS_ENV"] = "test"
require "rails"
require "rails/test_help"

# Configure test database
ActiveRecord::Base.establish_connection(
  adapter: "postgresql",
  database: "auto_cacher_test",
  username: "postgres",
  password: "postgres",
  host: "localhost",
  port: 5432
)

# Create test database if it doesn't exist
begin
  ActiveRecord::Base.connection
rescue ActiveRecord::NoDatabaseError
  ActiveRecord::Base.establish_connection(
    adapter: "postgresql",
    database: "postgres",
    username: "postgres",
    password: "postgres",
    host: "localhost",
    port: 5432
  )
  ActiveRecord::Base.connection.create_database("auto_cacher_test")
  ActiveRecord::Base.establish_connection(
    adapter: "postgresql",
    database: "auto_cacher_test",
    username: "postgres",
    password: "postgres",
    host: "localhost",
    port: 5432
  )
end

# Configure RSpec
RSpec.configure do |config|
  config.before(:suite) do
    # Ensure we're using the test database
    ActiveRecord::Base.connection.execute("SET search_path TO public")
  end

  config.after(:suite) do
    # Clean up any remaining tables
    ActiveRecord::Base.connection.tables.each do |table|
      ActiveRecord::Base.connection.drop_table(table, force: true)
    end
  end
end 