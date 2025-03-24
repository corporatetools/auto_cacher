# AutoCacher

A powerful caching system for Rails applications that automatically caches calculated fields and manages dedicated cache models. Built on top of [HallMonitor](https://github.com/corporatetools/hall_monitor) for efficient database change detection.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "auto_cacher", git: "https://github.com/corporatetools/auto_cacher.git"
```

And then execute:

```bash
$ bundle install
```

[[_TOC_]]

## 1. Introduction

AutoCacher is a **declarative caching system** that automates the caching of computed values. Instead of recalculating expensive queries every time they are needed, AutoCacher ensures that cached values remain up-to-date by detecting relevant data changes and triggering recalculations only when necessary.

### Example: AutoCacher in Action

To illustrate AutoCacher's usefulness, consider a scenario where we need to maintain an `unfulfilled_order_count` on the `customers` table. Instead of recalculating it dynamically each time it's needed, we can define a cacher to track changes and keep the field updated.

```ruby
class Customer < ApplicationRecord
  has_many :orders
end

class Customer::UnfulfilledOrderCountCacher < AutoCacher::Cacher
  configuration(
    # Defines which fields AutoCacher should monitor for changes
    watching: {
      Customer => [:status], # Changes to customer status may affect unfulfilled orders
      Order => [:customer_id, :status] # Changes to order status or reassignment impact counts
    },
    
    # Defines how to calculate the cached field value
    calculation: ->(record) {
      count_by_customer(record.id) || 0
    },
    
    # Determines which records need to be updated when a relevant change occurs
    records_to_update: ->(data_change) {
      affected_customer_ids = []

      if data_change.table == Order.table_name
        # If an order's status changes, update the associated customer's cache
        affected_customer_ids << data_change.record.customer_id
        
        # If an order is reassigned to a different customer, update both customers
        if data_change.field_changed?(:customer_id)
          affected_customer_ids << data_change.old_value_for(:customer_id)
        end
      elsif data_change.table == Customer.table_name
        # If a customer's status changes, update their cached count
        affected_customer_ids << data_change.record.id
      end

      Customer.where(id: affected_customer_ids.compact.uniq)
    }
  )

  # This method aggregates unfulfilled order counts by customer
  def self.count_by_customer(customer_ids = nil)
    relation = Order.where(status: 'unfulfilled')
    relation = relation.where(customer_id: customer_ids) if customer_ids
    relation.group(:customer_id).count
  end
end
```

### **Why This Matters**

By leveraging AutoCacher, we gain:

- **Efficient queries**: Instead of recalculating `unfulfilled_order_count` dynamically, the cached field is always up to date, eliminating redundant database queries.
- **Optimized list rendering**: This allows us to efficiently render a list of customers along with their `unfulfilled_order_count` **without causing N+1 queries**.
- **Fast lookups**: Querying customers with unfulfilled orders is now a simple indexed lookup instead of a costly join.
- **Encapsulation of Business Logic**: The logic for determining unfulfilled order counts is centralized in the cacher, making it easier to maintain and modify without spreading dependency logic across the application.
- **Reusable Aggregation Method**: The `count_by_customer` method allows other parts of the application to fetch authoritative unfulfilled order counts without duplicating query logic.

For example, fetching all customers with unfulfilled orders is now straightforward:

```ruby
Customer.where("unfulfilled_order_count > 0")
```

This enables further insights, such as:

- **Identifying dissatisfied customers**: Find customers with an unusually high number of unfulfilled orders:
  
  ```ruby
  Customer.where("unfulfilled_order_count > ?", 10)
  ```

- **Detecting potential neglect**: We could introduce another cacher to store the date of the **oldest unfulfilled order** for each customer, allowing us to find those whose issues have been unresolved for too long:
  
  ```ruby
  Customer.where("oldest_unfulfilled_order_date < ?", 30.days.ago)
  ```

By efficiently caching these values, we unlock powerful insights without performance overhead, making AutoCacher a valuable tool for maintaining scalable and performant applications.

---

## 2. Why Use AutoCacher?

- **Automated Cache Management**: Eliminates the need for manually updating cached fields.
- **Performance Optimized**: Reduces expensive database queries by storing precomputed values.
- **Declarative API**: Define cache logic in a structured way without cluttering model code.
- **Event-Driven Updates**: Caches are recalculated only when underlying data changes.
- **Scalable**: Works synchronously or asynchronously (via Sidekiq) for large-scale applications.
- **Centralized Cache Logic**: Each cacher class serves as the **authoritative aggregator** for a cached field, keeping related data and business logic in one place.

### How It Works

AutoCacher operates by:

1. **Defining Cachers**: Each cacher watches specific database fields and computes a derived value.
2. **Tracking Changes**: When a relevant field changes, AutoCacher determines which records need to be updated.
3. **Recalculating Values**: The cache values are recomputed and stored efficiently.
4. **Hooking into Callbacks**: Custom logic can be executed when cache values are updated.
5. **Encapsulating Business Logic**: Each cacher class is responsible for managing the logic used to compute its field, preventing scattered dependencies that could lead to cache invalidation issues.

> **⚠️ Managing Cache Invalidation:** Ensuring cache correctness is one of the hardest challenges in caching. See [Cache Invalidation Considerations](#cache-invalidation-considerations) for details on handling dependencies and avoiding common pitfalls.

---

## 3. Installation & Setup

### HallMonitor Dependency

AutoCacher depends on [HallMonitor](https://github.com/corporatetools/hall_monitor) for field tracking via HallMonitor::FieldMap and HallMonitor::DataChange.

### Step 1: Ensure AutoCacher is Present

AutoCacher must be included as part of the application's codebase. Ensure the following directory structure exists:

```
lib/
  auto_cacher/
    recalculation_worker.rb
    active_record_extensions.rb
    cacher.rb
  auto_cacher.rb
```

### Step 2: Configure AutoCacher

Create an initializer at `config/initializers/auto_cacher.rb` to configure AutoCacher:

```ruby
Rails.application.config.to_prepare do
  # Extend ActiveRecord models with AutoCacher support
  ActiveRecord::Base.include(AutoCacher::ActiveRecordExtensions)

  # Register all cachers with HallMonitor to track field changes
  AutoCacher.on_cacher_registry do |cacher|
    HallMonitor.register_watcher(
      HallMonitor::Watcher.new(
        field_map: cacher.watching, # Defines the fields this cacher monitors
        operations: cacher.operations, # Specifies the types of operations that trigger updates
        callback: ->(data_change) { cacher.call(data_change) } # Triggers recalculation when changes occur
      )
    )
  end

  # Ensure dedicated models are tracked for creation
  AutoCacher.configure_dedicated_model do |dedicated_auto_cacher_klass|
    if dedicated_auto_cacher_klass.respond_to?(:table_name)
      HallMonitor.register_watcher(
        HallMonitor::Watcher.new(
          field_map: dedicated_auto_cacher_klass.auto_cacher_dedicated_to_klass,
          operations: [:create],
          callback: ->(data_change) {
            dedicated_cacher_record = data_change.record.dedicated_auto_cacher
            dedicated_cacher_record.auto_cacher_populate_and_save!
          }
        )
      )
    end
  end

  # Load all cacher classes proactively so they register themselves
  cachers_path = Rails.root.join('app', 'cachers', '**', '*.rb')
  Dir[cachers_path].each { |file| require_dependency file }

  # Register all cachers now that they are loaded
  AutoCacher.register_all_cachers_from_loaded_object_memory
end
```

### Step 3: Register Dynamic Cachers

If a cacher is dynamically defined or loaded at a later point, it must be explicitly registered:

```ruby
AutoCacher.register_cacher(MyDynamicCacher)
```

---

## 4. Core Concepts

AutoCacher provides a structured way to manage computed values efficiently. This section covers its fundamental concepts, including how cachers define calculations, what triggers recalculations, when to use dedicated models, and how to hook into cache updates.

### Defining Cachers

A **cacher** is a class that defines how a specific field should be cached and kept up to date. It's recommended that each Cacher is defined in it's own file, inside `app/cachers/[name_of_model_with_cache_field]/[cacher_name].rb`. Wherever you put them, be sure you preemptively load all defined cachers when loading your application, probably in an initializer.

Each cacher defines:

- **`watching`**: Specifies which fields AutoCacher should monitor for changes. When a change occurs in any of these fields, AutoCacher will determine if a recalculation is necessary.
- **`calculation`**: Defines how the cached value should be computed for the ActiveRecord object received. This method receives the record that holds the cache field and must return the new computed value.
- **`records_to_update`**: Determines which records need to be updated, based upon the changes described by the `HallMonitor::DataChange` object received. This method must return a relation of all records that require recalculation of the field your cacher is managing.

**Example: Tracking Order Processing Status**

A cached field could store any kind of data. For a more complex example, we can store **a JSON summary** of key order details:

```ruby
class Order::ProcessingSummaryCacher < AutoCacher::Cacher
  configuration(
    watching: {
      Order => [:assigned_worker_id],
      Worker => [:name],
      Product => [:qty_in_stock]
    },

    # Computes the cached summary for an order
    calculation: ->(record) {
      {
        assigned_worker_name: assigned_worker_name_by_order(record.id),
        products_awaiting_stock_count: products_awaiting_stock_count_by_order(record.id)
      }.to_json
    },

    # Determines which orders need to be updated based on what changed
    records_to_update: ->(data_change) {
      affected_order_ids = []

      if data_change.table == Order.table_name
        order = data_change.record
        affected_order_ids << order.id
      elsif data_change.table == Worker.table_name
        worker = data_change.record
        affected_order_ids += Order.where(assigned_worker_id: worker.id).pluck(:id)
      elsif data_change.table == Product.table_name
        product = data_change.record
        affected_order_ids += Order.joins(:products).where(products: { id: product.id }).pluck(:id)
      end

      Order.where(id: affected_order_ids.compact.uniq)
    }
  )

  # Retrieves the worker names assigned to one or more orders
  def self.assigned_worker_name_by_order(order_ids = nil)
    relation = Order.where(id: order_ids).pluck(:id, :assigned_worker_id).to_h
    worker_names = Worker.where(id: relation.values).pluck(:id, :name).to_h
    relation.transform_values { |worker_id| worker_names[worker_id] }
  end

  # Counts the number of products still awaiting stock for one or more orders
  def self.products_awaiting_stock_count_by_order(order_ids = nil)
    Order.joins(:products)
      .where(id: order_ids)
      .group(:id)
      .sum(:qty_in_stock)
  end
end
```

This allows easy querying for order summaries **without expensive joins**.

Keeping such data up to date also introduces complexity, so use wisely!

---

### How Cachers Work

1. Every defined **`AutoCacher::Cacher`** class, when loaded, is used to create and register a **`HallMonitor::Watcher`** that monitors the fields defined by the Cacher.
2. When the **`HallMonitor::Watcher`** detects a change to any field a cacher is watching, the data change is passed to **`records_to_update`**, which returns a relation of records that need updating.
3. AutoCacher iterates over the relation returned by **`records_to_update`**.
4. The **`calculation`** method is called on each iteration, passing each record model instance as an argument.
5. The calculated value is stored in the cache field on the record.

#### **Triggering a Manual Recalculation**

Although AutoCacher updates values automatically, recalculations can be manually triggered when necessary:

```ruby
AutoCacher.recalculate(Customer.where(id: 42), [:order_processing_summary])
```

> **⚠️ Efficient recalculations depend on proper use of indexes and well-written aggregation methods.** AutoCacher does not batch updates itself; developers must ensure queries are optimized.

---

### Dedicated Models: When and Why to Use Them

A database field used to store cache values could be on any table. If it caches something about a customer, for example, it could be on a `customers` table, but there might also be benefits to keeping all or some cached fields in a separate table dedicated to having records 1:1 with customers, which stores all or some of those cached values for the customers. This can help:

- Avoid **locking contention** on frequently updated primary tables.
- Improve **indexing and query performance**.
- Organize **cache fields separately** for clarity.

#### **How Dedicated Cachers Work**

A dedicated cacher model must use:

- **`auto_cacher_dedicated_to :model_name`** on the **cacher model**.
- **`has_dedicated_auto_cacher :cacher_association`** on the **primary model**.

These methods call `belongs_to` and `has_one` for you, so no additional associations are needed.

**Example: Dedicated Cache Model**

```ruby
class Customer < ApplicationRecord
  has_dedicated_auto_cacher :customer_cache, inverse_of: :customer
end

class CustomerCache < ApplicationRecord
  auto_cacher_dedicated_to :customer
end

class CustomerCache::ActiveOrderCountCacher < AutoCacher::Cacher
  configuration(
    watching: { Order => [:customer_id, :status] },
    calculation: ->(record) {
      Order.where(customer_id: record.customer_id, status: "active").count
    },
    records_to_update: ->(data_change) {
      affected_customer_ids = [data_change.record.customer_id]
      if data_change.field_changed?(:customer_id)
        affected_customer_ids << data_change.old_value_for(:customer_id)
      end
      CustomerCache.where(customer_id: affected_customer_ids)
    }
  )
end
```

> **🚨 When using a dedicated model, both `calculation` and `records_to_update` operate on that dedicated model, NOT the model it is dedicated to.**

---

### Callbacks & Events

AutoCacher provides several callbacks that allow developers to hook into various points of the caching process:

- **`on_cacher_registry`** – Called when a cacher class is defined and added to AutoCacher's registry. This is the key way to set up a HallMonitor::Watcher for the cacher to have it react to data changes. This should go in an initializer.

- **`configure_dedicated_model`** – Called when a dedicated ActiveRecord model is registered. This is where you would set up your logic for managing the 1:1 relationship with the model it is dedicated to. This should go in an initializer.

- **`after_dedicated_model_creation`** – Called after a dedicated ActiveRecord model record is created. Useful for initializing related data or running post-creation logic.

Example Usage

```ruby
AutoCacher.on_cacher_registry do |cacher|
  # Add a HallMonitor watcher that watches all fields the cacher cares about.
  # This will trigger a recalculation (if needed) when any of the watched fields change.
  HallMonitor.register_watcher(
    HallMonitor::Watcher.new(
      field_map: cacher.watching,
      operations: cacher.operations,
      callback: ->(data_change) {
        cacher.call(data_change)
      }
    )
  )
end

AutoCacher.configure_dedicated_model do |model|
  # If the inherited class is dedicated to auto-caching a model, register a create watcher.
  # This will trigger a recalculation of all cache fields when a new dedicated cacher record is created.
  if dedicated_auto_cacher_klass.respond_to?(:table_name)
    HallMonitor.register_watcher(
      HallMonitor::Watcher.new(
        field_map: dedicated_auto_cacher_klass.table_name,
        operations: [:create],
        callback: ->(data_change) {
          data_change.record.auto_cacher_populate_and_save!
        }
      )
    )
  end
end

AutoCacher.after_dedicated_model_creation do |record|
  Rails.logger.info "Created dedicated cacher record for: #{record.inspect}"
end
```

These callbacks allow developers to extend AutoCacher's behavior and integrate it with logging, event systems, or other workflows.

---

## 5. Class Documentation

This section provides detailed documentation for the main classes in AutoCacher, including their available methods and usage examples.

### AutoCacher

The `AutoCacher` module serves as the central coordination point for defining, registering, and executing cache calculations. It manages field watchers, recalculations, and handles dependencies efficiently.

#### `register_all_cachers_from_loaded_object_memory`
Registers all defined cacher classes that are already loaded into memory. This is typically called at application startup after loading all cacher definitions.

```ruby
AutoCacher.register_all_cachers_from_loaded_object_memory
```

#### `register_cacher(cacher)`
Registers an individual cacher class or instance with AutoCacher. If a class is passed, it is instantiated automatically and then registered. Registering cachers is typically unnecessary, as this should be handled on application startup.

```ruby
AutoCacher.register_cacher(MyCustomCacher)
```

#### `recalculate(relation, fields)`
Triggers a manual recalculation for all records in a passed relation, limited to the cache fields specified.

```ruby
AutoCacher.recalculate(Customer.where(id: 42), [:unfulfilled_order_count])
```

#### `cachers_for_table(table_name)`
Returns all registered cachers that manage fields on the given table.

```ruby
AutoCacher.cachers_for_table("orders")
```

#### `find_cachers_for_table_and_field(table_name, field)`
Returns all registered cachers for a specific table and field.

```ruby
AutoCacher.find_cachers_for_table_and_field("orders", :status)
```

#### `cachers_for(table_or_klass, field = nil)`
Returns all cachers registered for a given table name or model class (from which a table is inferred). If a field is provided, it returns only the cachers related to that field.

```ruby
AutoCacher.cachers_for(Order, :status)
```

#### `dedicated_auto_cacher_models`
Returns all ActiveRecord model classes that are dedicated auto cachers.

```ruby
AutoCacher.dedicated_auto_cacher_models
```

#### `models_with_dedicated_auto_cachers`
Returns all primary models that have dedicated cacher models.

```ruby
AutoCacher.models_with_dedicated_auto_cachers
```

#### `all_managed_cache_fields`
Returns a hash of all cache fields represented by all cachers. Hash indexed by table name, with the values of each element being arrays of all cache fields on that table.

```ruby
AutoCacher.all_managed_cache_fields
```

### AutoCacher::Cacher

A `Cacher` is a class that defines how a specific field is cached and when it should be recalculated.

#### `call(data_change)`
Manually executes a cacher instance to update it's managed field on records affected by the given data change

```ruby
cacher_instance.call(data_change)
```

#### `recalculate_for(relation)`
Recalculates field for a given ActiveRecord relation.

```ruby
cacher_instance.recalculate_for(Order.where(status: 'pending'))
```

#### `configuration(options = {})`
Defines the configuration for the cacher, specifying which fields to watch, how to compute the cached value, and how to determine affected records.

```ruby
class OrderProcessingSummaryCacher < AutoCacher::Cacher
  configuration(
    watching: { Order => [:status] },
    calculation: ->(record) { Order.where(customer_id: record.id).count },
    records_to_update: ->(data_change) { Order.where(id: data_change.record.id) }
  )
end
```

#### `config(key, *args)`
Retrieves or sets a configuration value.

```ruby
cacher_instance.config(:watching)
cacher_instance.config(:watching, { Order => [:status] })
```

**example config options**
```ruby
cacher.watching  # Returns the list of fields being watched
cacher.field  # Returns the name of the cached field
cacher.klass  # Returns the ActiveRecord class the cacher is for
cacher.table  # Returns the table name associated with the cached field
cacher.records_to_update.call(data_change)  # Calls the proc to determine affected records
cacher.calculation.call(record)  # Calls the calculation method with the given record
```

### AutoCacher::ActiveRecordExtensions

AutoCacher provides ActiveRecord extensions that allow models to declare and interact with cache fields.

#### `is_dedicated_auto_cacher?`
Class method. True for model classes that use `auto_cacher_dedicated_to`. False otherwise.

#### `has_dedicated_auto_cacher?`
Class method. True for model classes that use `has_dedicated_auto_cacher`. False otherwise.

#### `dedicated_auto_cacher_klass`
Class method. Returns the class dedicated to managing cache records for the class on which it's called. nil otherwise.

#### `auto_cacher_dedicated_to_klass`
Class method. Returns the class to which the called upon class is dedicated to managing cache records for. nil otherwise.

#### `auto_cacher_populate_and_save!`
Recalculates and updates all cache fields on the record.

```ruby
customer.auto_cacher_populate_and_save!
```

#### `auto_cacher_populate(field_list = nil)`
Populates the given list of cache fields with fresh values without saving.

```ruby
customer.auto_cacher_populate([:unfulfilled_order_count])
```

#### `auto_cacher_for(field_name)`
Returns the `Cacher` instance responsible for managing a specific cache field.

```ruby
cacher = customer.auto_cacher_for(:unfulfilled_order_count)
```

#### `auto_cacher_calculate(field_name)`
Manually triggers the calculation logic for a cache field and returns the computed value.

```ruby
customer.auto_cacher_calculate(:unfulfilled_order_count)
```

#### `auto_cacher_fields`
Returns a hash of all cached fields on the model.

```ruby
customer.auto_cacher_fields
```

#### `dedicated_auto_cacher`
returns the model object the represents the dedicated auto cacher. Nil if none.

#### `auto_cacher_dedicated_to`
returns the object to which this object is dedicated to caching. Nil if none.


#### `has_dedicated_auto_cacher(association_name, *args, **kwargs)`
Declares that the model has a dedicated cache model.

```ruby
class Customer < ApplicationRecord
  has_dedicated_auto_cacher :customer_cache, inverse_of: :customer
end
```

#### `auto_cacher_dedicated_to(association_name, *args, **kwargs)`
Declares that the model is a dedicated cacher for another model.

```ruby
class CustomerCache < ApplicationRecord
  auto_cacher_dedicated_to :customer
end
```

---

## Cache Invalidation Considerations

Let's reexamine our example setup from earlier:

```ruby
class Customer::UnfulfilledOrderCountCacher < AutoCacher::Cacher
  configuration(
    watching: {
      Customer => [:status],
      Order => [:customer_id, :status]
    },
    calculation: ->(record) {
      count_by_customer(record.id) || 0
    },
    records_to_update: ->(data_change) {
      affected_customer_ids = []

      if data_change.table == Order.table_name
        affected_customer_ids << data_change.record.customer_id
        if data_change.field_changed?(:customer_id)
          affected_customer_ids << data_change.old_value_for(:customer_id)
        end
      elsif data_change.table == Customer.table_name
        affected_customer_ids << data_change.record.id
      end

      Customer.where(id: affected_customer_ids.compact.uniq)
    }
  )

  def self.count_by_customer(customer_ids = nil)
    relation = Order.where(status: 'unfulfilled')
    relation = relation.where(customer_id: customer_ids) if customer_ids
    relation.group(:customer_id).count
  end
end
```

This setup helps ensure that cache values remain up to date by keeping as much business logic as possible localized to this cacher. However, **if we had relied on a model-level scope instead of explicitly filtering `status: 'unfulfilled'` in the calculation method, any future changes to that scope could break our cache without warning**. Similarly, **if we hadn't accounted for `customer_id` changes, reassigned orders would leave incorrect counts in place**.

Even with this setup, new business logic elsewhere could introduce issues. For example:

- If customers marked as **delinquent** should not have unfulfilled orders counted, we'd need to update the cacher to watch `Customer.delinquent`.
- If we later introduce **discontinued products**, and unfulfilled orders for those shouldn't be counted, we'd need to update the cacher accordingly.
- Any changes to order filtering logic—such as introducing **order priority levels**—would require corresponding updates to ensure the cacher remains in sync.

To mitigate these risks, **consider keeping all relevant filtering logic inside the cacher whenever possible**. While not always feasible (such as in cases where ORM benefits outweigh the risk), maintaining a **single authoritative place for caching logic** makes it easier to reason about dependencies and ensure correctness.

Caching is hard. Be careful. Ensure all necessary dependencies are tracked when implementing cache logic.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/corporatetools/auto_cacher.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
