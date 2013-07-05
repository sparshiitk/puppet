# The injector is the "lookup service" class
#
# Initialization
# --------------
# The injector is initialized with a configured Binder. The Binder instance contains a resolved set of
# key => "binding information" that is used to setup the injector.
#
# Lookup
# ------
# It is possible to lookup the value, or a producer of the value. The {#lookup} method looks up a value, and the
# {#lookup_producer} looks up a producer.
# Both of these methods can be called with three different signatures; `lookup(key)`, `lookup(type, name)`, and `lookup(name)`,
# and `lookup_producer(key)`, `lookup_producer(type, name)`, and `lookup_producer(name)`.
#
# It is possible to pass a block to {#lookup} and {#lookup_producer}, the block is passed the result of the lookup
# and the result of the block is returned as the value of the lookup. This is useful in order to provide a default value.
#
# @example Lookup with default value
#   injector.lookup('favourite_food') {|x| x.nil? ? 'bacon' : x }
#
# Singleton or Not
# ----------------
# The lookup of a value is based on the lookup of a producer. For singleton producers this means that the value is
# determined by the first value lookup. Subsequent lookups via either method will produce the same instance.
#
# Non singleton producers will produce a new instance on each request for a value. For constant value producers this
# means that a new deep-clone is produced for mutable objects (but not for immutable objects as this is not needed).
# Custom producers should have non singleton behavior, or if this is not possible ensure that the produced result is
# immutable. (The behavior if a custom producer hands out a mutable value and this is mutated is undefined).
#
# Custom bound producers capable of producing a series of objects when bound as a singleton means that the producer
# is a singleton, not the value it produces. If such a producer is bound as non singleton, each `lookup` will get a new
# producer (hence, typically, restarting the series). However, if the producer returned from `lookup_producer` will not
# recreate the producer on each call to `produce`; i.e. each `lookup_producer` returns a producer capable of returning
# a series of objects.
#
# @see Puppet::Pops::Binder::Binder for details about how to bind keys to producers
# @see Puppet::Pops::Binder::BindingsFactory for a convenient way to create a Binder and bindings
#
# Assisted Inject
# ---------------
# The injector supports lookup of instances of classes even if the requested class is not explicitly bound.
# This is possible for classes that have a zero argument `initialize` method, or that has a class method called
# `inject` that takes two arguments; `injector`, and `scope`.
# This is useful in ruby logic as a class can then use the given injector to inject details.
# An `inject` class method wins over a zero argument `initialize` in all cases.
# 
# @example Using assisted inject
#   # Class with assisted inject support
#   class Duck
#     attr_reader :name, :year_of_birth
#
#     def self.inject(injector, scope)
#       # lookup default name and year of birth, and use defaults if not present
#       name = injector.lookup(scope,'default-duck-name') {|x| x ? x : 'Donald Duck' }
#       year_of_birth = injector.lookup(scope,'default-duck-year_of_birth') {|x| x ? x : 1934 }
#       self.new(name, year_of_birth)
#     end
#
#     def initialize(name, year_of_birth)
#       @name = name
#       @year_of_birth = year_of_birth
#     end
#   end
#
#   injector.lookup(scope, Duck)
#   # Produces a Duck named 'Donald Duck' or named after the binding 'default-duck-name' (and with similar treatment of
#   # year_of_birth
#
# @api public
#
class Puppet::Pops::Binder::Injector

  # Hash of key => InjectorEntry
  # @api private
  #
  attr_reader :entries

  # The KeyFactory used to produce keys in this injector.
  # The factory is shared with the Binder to ensure consistent translation to keys.
  # A compatible type calculator can also be obtained from the key factory.
  #
  # @api public
  #
  attr_reader :key_factory

  # An Injector is initialized with a configured Binder.
  #
  # @param configured_binder [Puppet::Pops::Binder::Binder] the configured binder containing effective bindings
  # @raises ArgumentError if the given binder is not fully configured
  #
  # @api public
  #
  def initialize(configured_binder)
    raise ArgumentError, "Given Binder is not configured" unless configured_binder && configured_binder.configured?()
    @entries             = configured_binder.injector_entries()

    # It is essential that the injector uses the same key factory as the binder since keys must be
    # represented the same (but still opaque) way.
    #
    @key_factory         = configured_binder.key_factory()
    @@transform_visitor ||= Puppet::Pops::Visitor.new(nil,"transform", 2,  2)
    @recursion_lock = []
  end

  # Lookup (a.k.a "inject") of a value given a key.
  # The lookup may be called with different parameters. This method is a convenience method that
  # dispatches to one of #lookup_key or #lookup_type depending on the arguments. It also provides
  # the ability to use an optional block that is called with the looked up value, or scope and value if the
  # block takes two paramters. This is useful to provide a default value or other transformations, calculations
  # based on the result of the lookup.
  #
  # @overload lookup(scope, key)
  #   (see #lookup_key)
  #   @param scope [Puppet::Parser::Scope] the scope to use for evaluation
  #   @param key [Object] an opaque object being the full key
  #
  # @overload lookup(scope, type, name = '')
  #  (see #lookup_type)
  #   @param scope [Puppet::Parser::Scope] the scope to use for evaluation
  #   @param type [Puppet::Pops::Types::PObjectType], the type of what to lookup
  #   @param name [String], the name to use, defaults to empty string (for unnamed)
  #
  # @overload lookup(scope, name)
  #  Lookup of Data type with given name.
  #   @see #lookup_type
  #   @param scope [Puppet::Parser::Scope] the scope to use for evaluation
  #   @param name [String], the Data/name to lookup
  #
  # @yield [value] passes the looked up value to an optional block and returns what this block returns
  #   @yieldparam value [Object, nil] the looked up value or nil if nothing was bound
  # @yield [scope, value] passes scope and value to the block and returns what this block returns
  #   @yieldparam scope [Puppet::Parser::Scope] the scope given to lookup
  #   @yieldparam value [Object, nil] the looked up value or nil if nothing was bound
  #
  # @raises [ArgumentError] if the block has an arity that is not 1 or 2
  #
  # @api public
  #
  def lookup(scope, *args, &block)
    raise ArgumentError, "lookup should be called with two or three arguments, got: #{args.size()+1}" unless args.size.between?(1,2)
    val = case args[0]
    when Puppet::Pops::Types::PObjectType
      lookup_type(scope, *args)
    when String
      raise ArgumentError, "lookup of name should only pass the name" unless args.size == 1
      lookup_key(scope, key_factory.data_key(args[0]))
    else
      raise ArgumentError, "lookup using a key should only pass a single key" unless args.size == 1
      lookup_key(scope, args[0])
    end
    if block
      case block.arity
      when 1
        block.call(val)
      when 2
        block.call(scope, val)
      else
        raise ArgumentError, "The block should have arity 1 or 2"
      end
    else
      val
    end
  end

  # Produces a key for a type/name combination.
  # Specialization of the PDataType are transformed to a PDataType key
  # This is a convenience method for the method with the same name in {Puppet::Pops::Binder::KeyFactory}.
  #
  # @see #key_factory
  # @param type [Puppet::Pops::Types::PObjectType], the type the key should be based on
  # @param name [String]='', the name to base the key on for named keys.
  #
  # @api public
  #
  def named_key(type, name)
    key_factory.named_key(type, name)
  end

  # Produces a key for a PDataType/name combination
  # This is a convenience method for the method with the same name in {Puppet::Pops::Binder::KeyFactory}.
  #
  # @see #key_factory
  # @param name [String], the name to base the key on.
  #
  # @api public
  #
  def data_key(name)
    key_factory.data_key(name)
  end

  # Returns the TypeCalculator in use for keys. The same calculator (as used for keys) should be used if there is a need
  # to check type conformance, or infer the type of Ruby objects.
  #
  # @return [Puppet::Pops::Types::TypeCalculator] the type calculator that is in use for keys
  # @api public
  #
  def type_calculator()
    key_factory.type_calculator
  end

  # Looks up a (typesafe) value based on a type/name combination.
  # Creates a key for the type/name combination using a KeyFactory. Specialization of the Data type are transformed
  # to a Data key, and the result is type checked to conform with the given key.
  #
  # TODO: Detailed error message
  #
  # @param type [Puppet::Pops::Types::PObjectType] the type to lookup as defined by Puppet::Pops::Types::TypeFactory
  # @param name [String] the (optional for non `Data` types) name of the entry to lookup.
  #   The name may be an empty String (the default), but not nil. The name is required for lookup for subtypes of
  #   `Data`.
  # @return [Object, nil] the looked up bound object, or nil if not found (type conformance with given type is guaranteed)
  # @raises [ArgumentError] if the produced value does not conform with the given type
  #
  # @api public
  #
  def lookup_type(scope, type, name='')
    val = lookup_key(scope, named_key(type, name))
    unless key_factory.type_calculator.instance?(type, val)
      raise ArgumentError, "Type error: incompatible type TODO: detailed error message"
    end
    val
  end

  # Looks up the key and returns the entry, or nil if no entry is found.
  # Produced type is checked for type conformance with its binding, but not with the lookup key.
  # (This since all subtypes of PDataType are looked up using a key based on PDataType).
  # Use the Puppet::Pops::Types::TypeCalculator#instance? method to check for conformance of the result
  # if this is wanted, or use #lookup_type.
  #
  # TODO: Detailed error message
  #
  # @param key [Object] lookup of key as produced by the key factory
  # @return [Object] produced value of type that conforms with bound type (type conformance with key not guaranteed).
  # @raises [ArgumentError] if the produced value does not conform with the bound type
  #
  # @api public
  #
  def lookup_key(scope, key)
    if @recursion_lock.include?(key)
      raise ArgumentError, "Lookup loop detected for key: #{key}"
    end
    begin
      @recursion_lock.push(key)
      case entry = get_entry(key)
      when NilClass
        nil
      when Puppet::Pops::Binder::InjectorEntry
        val = produce(scope, entry)
        return nil if val.nil?
        unless key_factory.type_calculator.instance?(entry.binding.type, val)
          raise "Type error: incompatible type returned by producer TODO: detailed error message"
        end
        val
      when Puppet::Pops::Binder::AssistedInjectProducer
        entry.produce(scope)
      else
        # internal, direct entries
        entry
      end
    ensure
      @recursion_lock.pop()
    end
  end

  # @api private
  def get_entry(key)
    case entry = entries[key]
    when NilClass
      # not found, is this an assisted inject?
      if clazz = assistable_injected_class(key)
        entry = Puppet::Pops::Binder::AssistedInjectProducer.new(self, clazz)
        entries[key] = entry
      else
        entries[key] = NotFound.new()
        entry = nil
      end
    when NotFound
      entry = nil
    end
    entry
  end

  def assistable_injected_class(key)
    kt = key_factory.get_type(key)
    return nil unless kt.is_a?(Puppet::Pops::Types::PRubyType) && !key_factory.is_named?(key)
    type_calculator.injectable_class(kt)
  end

  # Lookup (a.k.a "inject") producer of a value given a key.
  # The producer lookup may be called with different parameters. This method is a convenience method that
  # dispatches to one of #lookup_producer_key or #lookup_producer_type depending on the arguments. It also provides
  # the ability to use an optional block that is called with the looked up producer, or scope and producer if the
  # block takes two parameters. This is useful to provide a default value, call a custom producer method,
  # or other transformations, calculations based on the result of the lookup.
  #
  # @overload lookup_producer(scope, key)
  #   (see #lookup_proudcer_key)
  #   @param scope [Puppet::Parser::Scope] the scope to use for evaluation
  #   @param key [Object] an opaque object being the full key
  #
  # @overload lookup_producer(scope, type, name = '')
  #  (see #lookup_type)
  #   @param scope [Puppet::Parser::Scope] the scope to use for evaluation
  #   @param type [Puppet::Pops::Types::PObjectType], the type of what to lookup
  #   @param name [String], the name to use, defaults to empty string (for unnamed)
  #
  # @overload lookup_producer(scope, name)
  #  Lookup of Data type with given name.
  #   @see #lookup_type
  #   @param scope [Puppet::Parser::Scope] the scope to use for evaluation
  #   @param name [String], the Data/name to lookup
  #
  # @return [Puppet::Pops::Binder::Producer, Object, nil] a producer, or what the optional block returns
  #
  # @yield [producer] passes the looked up producer to an optional block and returns what this block returns
  #   @yieldparam producer [Puppet::Pops::Binder::Producer, nil] the looked up producer or nil if nothing was bound
  #
  # @yield [scope, producer] passes scope and producer to the block and returns what this block returns
  #   @yieldparam scope [Puppet::Parser::Scope] the scope given to lookup
  #   @yieldparam producer [Object, nil] the looked up producer or nil if nothing was bound
  #
  # @raises [ArgumentError] if the block has an arity that is not 1 or 2
  #
  # @api public
  #
  def lookup_producer(scope, *args, &block)
    raise ArgumentError, "lookup_producer should be called with two or three arguments, got: #{args.size()+1}" unless args.size <= 2
    p = case args[0]
    when Puppet::Pops::Types::PObjectType
      lookup_producer_type(scope, *args)
    when String
      raise ArgumentError, "lookup_producer of name should only pass the name" unless args.size == 1
      lookup_producer_key(scope, key_factory.data_key(args[0]))
    else
      raise ArgumentError, "lookup_producer using a key should only pass a single key" unless args.size == 1
      lookup_producer_key(scope, args[0])
    end
    if block
      case block.arity
      when 1
        block.call(p)
      when 2
        block.call(scope, p)
      else
        raise ArgumentError, "The block should have arity 1 or 2"
      end
    else
      p
    end
  end

  # Looks up a Producer given an opaque binder key.
  # @returns [Puppet::Pops::Binder::Producer, nil] the bound producer, or nil if no such producer was found.
  #
  # @api public
  #
  def lookup_producer_key(scope, key)
    if @recursion_lock.include?(key)
      raise ArgumentError, "Lookup loop detected for key: #{key}"
    end
    begin
      @recursion_lock.push(key)
      producer(scope, get_entry(key), :multiple_use)
    ensure
      @recursion_lock.pop()
    end
  end

  # Looks up a Producer given a type/name key.
  # @note The result is not type checked (it cannot be until the producer has produced an instance).
  # @returns [Puppet::Pops::Binder::Producer, nil] the bound producer, or nil if no such producer was found
  #
  # @api public
  #
  def lookup_producer_type(scope, type, name='')
    lookup_producer_key(scope, named_key(type, name))
  end

  # Returns the producer for the entry
  # @return [Puppet::Pops::Binder::Producer] the entry's producer.
  #
  # @api private
  #
  def producer(scope, entry, use)
    return nil unless entry # not found
    return entry.producer(scope) if entry.is_a?(Puppet::Pops::Binder::AssistedInjectProducer)
    unless entry.cached_producer
      entry.cached_producer = transform(entry.binding.producer, scope, entry)
    end
    raise ArgumentError, "Injector entry without a producer TODO: detail" unless entry.cached_producer
    entry.cached_producer.producer(scope)
  end

  def transform(producer_descriptor, scope, entry)
    @@transform_visitor.visit_this(self, producer_descriptor, scope, entry)
  end

  # Creates a producer if given argument is a lambda, else returns the give producer
  # @return [Puppet::Pops::Binder::Producer] the given or producer wrapped lambda producer
  # @api private
  #
  def create_producer(lambda_or_producer)
    return lambda_or_producer if lambda_or_producer.is_a?(Puppet::Pops::Binder::Producer)
    return Puppet::Pops::Binder::LambdaProducer.new(lambda_or_producer)
  end

  # Returns the produced instance
  # @return [Object] the produced instance
  # @api private
  #
  def produce(scope, entry)
    return nil unless entry # not found
    producer(scope, entry, :single_use).produce(scope)
  end

  # Handles a  missing producer (which is valid for a Multibinding where one is selected automatically
  # @api private
  #
  def transform_NilClass(descriptor, scope, entry)
    # TODO: When the multibind has a nil producer it is not possible to flag it as being
    # singleton or not - in this case the collected content will need to determine its state
    # the issue is if a collected piece of content is dynamic as each multi lookup could potentially
    # be different. (Uncertain if this is an issue...)
    #

    unless entry.binding.is_a?(Puppet::Pops::Binder::Bindings::Multibinding)
      raise ArgumentError, "Binding without producer detected (TODO: details)"
    end
    case entry.binding.type
    when Puppet::Pops::Types::PArrayType
      array_multibind_producer(entry.binding)
    when Puppet::Pops::Types::PHashType
      hash_multibind_producer(entry.binding)
    else
      raise ArgumentError, "Unsupported multibind type, must be an array or hash type, but got: '#{entry.binding.type}"
    end
  end

  # @api private
  def transform_ArrayMultibindProducerDescriptor(descriptor, entry)
    p = array_multibind_producer(entry.binding)
    singleton?(descriptor) ? singleton_producer(p.produce(scope)) : p
  end

  # @api private
  def transform_HashMultibindProducerDescriptor(descriptor, entry)
    p = hash_multibind_producer(entry.binding)
    singleton?(descriptor) ? singleton_producer(p.produce(scope)) : p
  end

  # Produces a constant value
  # If not a singleton the value is deep-cloned (if not immutable) before returned.
  # @api private
  #
  def transform_ConstantProducerDescriptor(descriptor, scope, entry)
    create_producer(singleton?(descriptor) ? singleton_producer(descriptor.value) : deep_cloning_producer(descriptor.value))
  end

  # Produces a new instance of the given class with given initialization arguments
  # If a singleton, the producer is asked to produce a single value and this is then considered a singleton.
  # @api private
  #
  def transform_InstanceProducerDescriptor(descriptor, scope, entry)
    x = instantiating_producer(descriptor.class_name, *descriptor.arguments)
    create_producer(singleton?(descriptor) ? singleton_producer(x.produce(scope)) : x)
  end

  # Evaluates a contained expression. If this is a singleton, the evaluation is performed once.
  # @api private
  #
  def transform_EvaluatingProducerDescriptor(descriptor, scope, entry)
    x = evaluating_producer(descriptor.expression)
    create_producer(singleton?(descriptor) ? singleton_producer(x.produce(scope)) : x)
  end

  # @api private
  def transform_ProducerProducerDescriptor(descriptor, scope, entry)
    p = transform(descriptor.producer, scope, entry)
    singleton?(descriptor) ? singleton_producer_producer(p, scope) : producer_producer(p)
  end

  # @api private
  def transform_LookupProducerDescriptor(descriptor, scope, entry)
    x = injecting_producer(descriptor.type, descriptor.name)
    create_producer(singleton?(descriptor) ? singleton_producer(x.produce(scope)) : x)
  end

  # @api private
  def transform_HashLookupProducerDescriptor(descriptor, scope, entry)
    x = injecting_key_producer(descriptor.type, descriptor.name, descriptor.key)
    create_producer(singleton?(descriptor) ? singleton_producer(x.produce(scope)) : x)
  end

  # This implementation simply delegates since caching status is determined by the polymorph transform_xxx method
  # per type (different actions taken depending on the type).
  # @api private
  #
  def transform_NonCachingProducerDescriptor(descriptor, scope, entry)
    # simply delegates to the wrapped producer
    transform(descriptor.producer, scope, entry)
  end

  # @api private
  def transform_FirstFoundProducerDescriptor(descriptor, scope, entry)
    x = first_found_producer(descriptor.producers.collect {|p| transform(p, scope, entry) })
    create_producer(singleton?(descriptor) ? singleton_producer(x).produce(scope) : x)
  end

  private

  def singleton?(descriptor)
    ! descriptor.eContainer().is_a?(Puppet::Pops::Binder::Bindings::NonCachingProducerDescriptor)
  end

  def singleton_producer(value)
    create_producer(lambda {|scope| value })
  end

  # Produces in two steps
  def producer_producer(producer)
    Puppet::Pops::Binder::ProducerProducer.new(producer)
  end

  # Caches first produce step, and performs the next over and over again
  def singleton_producer_producer(producer, scope)
    p = producer.produce(scope)
    create_producer(lambda {|scope| p.produce(scope) })
  end

  def deep_cloning_producer(value)
    x = lambda do |scope|
      case value
      # These are immutable
      when Integer, Float, TrueClass, FalseClass, Symbol
        return value
      # ok if frozen
      when String
        return value if value.frozen?
      end

      # The default serialize/deserialize to get a deep copy
      Marshal.load(Marshal.dump(value))
    end
    create_producer(x)
  end

  def instantiating_producer(class_name, *init_args)
    # get class by name
    the_class = type_calculator.class_get(class_name)
    create_producer(lambda {|scope| the_class.new(*init_args) } )
  end

  def first_found_producer(producers)
    # return the first produced value that is non-nil (unfortunately there is no such enumerable method)
    create_producer(lambda {|scope| producers.reduce(nil) {|memo, p| break memo unless memo.nil?; p.produce(scope)}})
  end

  def evaluating_producer(expr)
    puppet3_ast = Puppet::Pops::Model::AstTransformer.new().transform(expr)

    the_lambda = lambda do |scope|
      begin
        # Must CHEAT as the expressions must have access to array/hash concat/merge
        current_parser = Puppet[:parser]
        Puppet[:parser] = 'future'
        puppet3_ast.evaluate(scope)
      ensure
        # Stop cheating
        Puppet[:parser] = current_parser
      end
    end

    create_producer(the_lambda)
  end

  def injecting_producer(type, name)
    create_producer( lambda { |scope| lookup_type(scope, type, name) })
  end

  def injecting_key_producer(type, name, key)
    x = lambda do |scope|
      result = lookup_type(scope, type, name)
      result.is_a?(Hash) ? result[key] : nil
      end
    create_producer(x)
  end

  def create_array_combinator(scope, multibinding)
    case multibinding.combinator
    when NilClass
       Puppet::Pops::Binder::MultibindCombinators::ArrayCombinator.new()
    when Puppet::Pops::Binder::Bindings::CombinatorLambda
      ast31lambda = Puppet::Pops::Model::AstTransformer.new().transform(multibinding.combinator.lambda())
      Puppet::Pops::Binder::MultibindCombinators::ArrayPuppetLambdaCombinator.new(ast31lambda)
    when Puppet::Pops::Binder::Bindings::CombinatorProducer
      transform(multibinding.combinator).produce(scope)
    end
  end

  def create_hash_combinator(scope, multibinding)
    case multibinding.combinator
    when NilClass
      Puppet::Pops::Binder::MultibindCombinators::HashCombinator.new()
    when Puppet::Pops::Binder::Bindings::CombinatorLambda
      ast31lambda = Puppet::Pops::Model::AstTransformer.new().transform(multibinding.combinator.lambda())
      Puppet::Pops::Binder::MultibindCombinators::HashPuppetLambdaCombinator.new(ast31lambda)
    when Puppet::Pops::Binder::Bindings::CombinatorProducer
      transform(multibinding.combinator).produce(scope)
    end
  end

  # @api private
  def array_multibind_producer(binding)
    contributions_key = key_factory.multibind_contributions(binding.id)
    x = lambda do |scope|
      combinator = create_array_combinator(scope, binding)
      # transform array of keys to an array of looked up values
      lookup_key(scope, contributions_key).reduce([]) do |memo, k|
        combinator.combine(scope, binding, type_calculator, memo, lookup_key(scope, k))
      end
    end
    create_producer(x)
  end

  # @api private
  def hash_multibind_producer(binding)
    contributions_key = key_factory.multibind_contributions(binding.id)
    x = lambda do |scope|
      result = {}
      lookup_key(scope, contributions_key).each do |k|
        # get the entry (its name is needed)
        entry = get_entry(k)
        raise ArgumentError, "Internal Error: Entry in multibind missing: #{k} for contributions: #{contributions_key}" unless entry
        name = entry.binding.name

        combinator = create_hash_combinator(scope, binding)
        result[entry.binding.name] = combinator.combine(scope, binding, type_calculator, result, name, result[name], lookup(scope, k))
      end
      result
    end
    create_producer(x)
  end

  # Special marker class used in entries
  class NotFound
  end
end