require 'json'

class Register
  Field = Struct.new :name, :datatype, :text, :cardinality

  attr_reader :name
  attr_reader :indexes

  def initialize orc
    @orc = orc
    @indexes = Hash.new {|hash, key| hash[key] = Hash.new {|hash, key| hash[key] = [] }}
  end

  def init name, organisation, text, *fields
    @orc.new_register name
    @name = name
    append_entry :system, 'name', {name: name}
    append_entry :system, "register:#{name}", {
      'fields': fields.map(&:name),
      'register': name,
      'registry': organisation,
      'text': text
    }
    fields.each do |field|
      append_entry :system, "field:#{field.name}", {
        'field': field.name,
        'cardinality': field.cardinality || 1,
        'datatype': field.datatype.to_s.downcase,
        'text': field.text
      }
    end
    add_index name.to_sym
  end

  def custodian= name
    append_entry :system, 'custodian', {custodian: name}
  end

  def add_index name
    @indexes[name]
  end

  def find attr, value
    @indexes[attr][value]
  end

  def items
    @indexes[@name.to_sym].values.flatten
  end

  def append_entry region, key, item
    raise "region cannot be nil" if region.nil?
    raise "key cannot be nil" if key.nil?
    raise "incorrect key for item" if region == :user && key != item[@name.to_sym]
    @orc.ensure_entry @name, region, key, JSON.dump(item)
    add_to_indexes item
  end

  def add_to_indexes item
    @indexes.keys.each do |attr|
      value = item[attr]
      next unless value
      @indexes[attr][value] = @indexes[attr][value].push(item)
    end
  end

  def finish!
    @orc.delete_untouched @name, 'system'
    @orc.delete_untouched @name, 'user'
  end

  def to_rsf filename
    @orc.to_rsf @name, filename
  end
end

class MultiItemRegister < Register
  def append_entry region, key, item
    if region == :system
      super
    else
      add_to_indexes item
    end
  end

  def finish!
    @indexes[@name.to_sym].keys.each do |key|
      items = @indexes[@name.to_sym][key]
      jsons = items.map &JSON.method(:dump)
      @orc.ensure_entry @name, :user, key, *jsons
    end
    super
  end
end