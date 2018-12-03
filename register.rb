require 'json'
require 'digest'

SHA256 = Digest::SHA2.new 256
DATE_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

class Register
  Field = Struct.new :name, :datatype, :text, :cardinality

  attr_reader :items

  def initialize filename
    @io = File.open filename, 'w'
    @items = []
  end

  def hash object
    "sha-256:#{SHA256.hexdigest(object)}"
  end

  def init name, organisation, text, *fields
    @io.write "assert-root-hash\t#{hash('')}\n"
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
  end

  def custodian= name
    append_entry :system, 'custodian', {custodian: name}
  end

  def append_entry region, key, item, time=Time.now
    json = JSON.dump item
    #STDERR.puts "orc append-entry #{@io.path} #{region} #{key} #{json}"

    raise "region cannot be nil" if region.nil?
    raise "key cannot be nil" if key.nil?
    @items << item
    @io.write "add-item\t#{json}\n"
    @io.write "append-entry\t#{region}\t#{key}\t#{time.utc.strftime(DATE_FORMAT)}\t#{hash(json)}\n"
  end

  def close
    @io.close
    @io = nil
  end
end
