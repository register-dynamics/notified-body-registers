require 'open-uri'
require 'nokogiri'
require 'base64'
require_relative 'register'
require_relative 'orc'

DIRECTIVE_CODE = /\d+\/\d+(\/[A-Z]+)?/

WHITESPACE_WITH_NBSP = /\s|\u00A0/

RSFs = FileList[
  'legislation.rsf',
  'product.rsf',
  'annex.rsf',
  'body-type.rsf',
  'body.rsf'
]
CACHE = './cache/'
STORE = 'nando.catalogue.sqlite'

def nando_rel_link page
  "http://ec.europa.eu/growth/tools-databases/nando/#{page}"
end

def nando action
  nando_rel_link "index.cfm?fuseaction=#{action}"
end

def cached href
  File.join CACHE, "#{Base64.urlsafe_encode64(href, padding: false)}.html"
end

def page href
  filename = cached href
  unless File.exist? filename
    rake_output_message "GET #{href}"
    File.write filename, open(href, &:read)
  end

  open(filename, &Nokogiri.method(:HTML))
end

def parse_legislation_text text
  words, code, name = text.strip.partition(DIRECTIVE_CODE)
  legislation_id = words + code
  [legislation_id, name]
end

def progress done, total
  msg = "Progress: #{done}/#{total}"
  STDERR.write msg
  STDERR.write "\b" * msg.length
end

task :default => RSFs

directory CACHE

task :clean do
  rm RSFs
  rm STORE
end

task :mrproper => :clean do
  rm_r CACHE
end

file 'legislation.rsf' do |t|
  orc = Orc.new STORE
  legislation = Register.new orc
  legislation.init(
    'legislation',
    'European-Commission',
    'EU product harmonisation legislation - can be in the form of a Directive, a Regulation or a Decision.',
    Register::Field.new('legislation', 'string', 'Unique code or text that identifies the legislation.', 1),
    Register::Field.new('name', 'string', 'Summary of types of products that the legislation covers.', 1))
  legislation.custodian = 'Simon Worthington'

  legislation_page = page nando('directive.main')
  legislation_page.css('#main_content table table tr').each do |legislation_row|
    text = legislation_row.css('a').first.text.strip
    legislation_id, name = parse_legislation_text text

    legislation.append_entry :user, legislation_id, {legislation: legislation_id, name: name.strip}
  end
  legislation.finish!
  orc.close
  legislation.to_rsf t.name
end

def find_legislation_page legislation_id
  legislation_page = page nando_rel_link('index.cfm?fuseaction=notifiedbody.notifiedbodies&num=DNB&text=')
  dir_id = legislation_page.css('select[name="dir_id"] option').find do |option|
    text = option.text.strip
    parsed_legislation_id, _ = parse_legislation_text text
    legislation_id == parsed_legislation_id
  end.attribute('value').value
  "index.cfm?fuseaction=directive.notifiedbody&dir_id=#{dir_id}"
end

def truncated_string_match? full, maybe_truncated, truncation='...'
  # downcases sadly necessary, data quality is odd
  if maybe_truncated.end_with? truncation
    full.downcase.start_with? maybe_truncated[0...-(truncation.length)].downcase
  else
    full.downcase == maybe_truncated.downcase
  end
end

file 'body.rsf' do
  orc = Orc.new STORE
  products = MultiItemRegister.new orc
  products.init(
    'product',
    'European-Commission',
    'Products covered by a particular EU product Directive/Regulation.',
    Register::Field.new('product', 'integer', 'The NANDO unique identifier for these products.', 1),
    Register::Field.new('legislation', 'curie', 'The item of EU legislation that covers the products.', 1),
    Register::Field.new('description', 'string', 'Description of product types covered.', 1),
    Register::Field.new('parent', 'curie', 'The NANDO unique identifier for the parent product category, if this product has one.', 1)
  )
  products.custodian = 'Simon Worthington'
  products.add_index :description

  find_product_id = proc do |legislation_id, description, parent|
    listing_link = nando_rel_link find_legislation_page legislation_id
    listing_page = page listing_link
    product_option = listing_page.css('table table select[name="pro_id"] option').find do |option|
      truncated_string_match? description, option.text.strip
    end
    product_option ||= begin
      parent = products.find(:product, parent).first
      listing_page.css('table table select[name="pro_id"] option').find do |option|
        truncated_string_match? "#{parent[:description]} (#{description})", option.text.strip
      end
    end
    raise "Unable to find product #{description.inspect} [#{parent}] in #{cached listing_link}" if product_option.nil?
    product_option.attribute('value').value.to_i
  end

  find_or_add_product = proc do |legislation_id, description, parent|
    matching_products = products.find :description, description
    product = matching_products.find {|p| p[:description] == description && p[:parent] == (parent.nil? ? nil : "product:#{parent}") && p[:legislation] == "legislation:#{legislation_id}" }
    if product.nil?
      product = {
        product: find_product_id.call(legislation_id, description, parent),
        legislation: "legislation:#{legislation_id}",
        description: description,
        parent: (parent.nil? ? nil : "product:#{parent}")
      }
      products.append_entry :user, product[:product], product
    end
    product
  end

  annexes = MultiItemRegister.new orc
  annexes.init(
    'annex',
    'European-Commission',
    'An Annex or Article of a peice of Legislation that defines a conformity assessment procedure, as set out in Annex II of Decision 758/2008/EC and in the relevant EU product legislation',
    Register::Field.new('annex', 'string', 'The NANDO unique identifier for this annex.', 1),
    Register::Field.new('name', 'string', 'Human-readable name of the annex.', 1),
    Register::Field.new('legislation', 'curie', 'The item of EU legislation that includes the procedure.', 1),
    Register::Field.new('procedures', 'string', 'Summaries of the procedures that the annex defines.', 'n'),
  )
  annexes.custodian = 'Simon Worthington'
  annexes.add_index :name

  find_annex_id = proc do |legislation_id, name, procedures|
    listing_link = nando_rel_link find_legislation_page legislation_id
    listing_page = page listing_link
    value = listing_page.css('table table select[name="prc_anx"] option').find do |option|
      truncated_string_match? "#{procedures.first} / #{name}", option.text.strip
    end.attribute('value').value
    "#{legislation_id}:#{value}"
  end

  find_or_add_annex = proc do |legislation_id, name, procedures|
    matching_annexes = annexes.find :name, name
    annex = matching_annexes.find {|p| p[:name] == name && p[:legislation] == "legislation:#{legislation_id}" }
    if annex.nil?
      annex = {
        annex: find_annex_id.call(legislation_id, name, procedures),
        legislation: "legislation:#{legislation_id}",
        name: name.strip,
        procedures: procedures
      }
      annexes.append_entry :user, annex[:annex], annex
    else
      annex[:procedures] = annex[:procedures] | procedures
    end
    annex
  end

  bodies = Register.new orc
  bodies.init(
    'body',
    'European-Commission',
    'Organisations that, having fulfilled the relevant requirements, are designated to carry out conformity assessment according to specific legislation.',
    Register::Field.new('body', 'string', 'The NANDO unique identifier for this body.'),
    Register::Field.new('type', 'curie', 'The unique code for the type that this body is.'),
    Register::Field.new('notified-body-number', 'integer', 'The unique number assigned to this body if it has notified.'),
    Register::Field.new('name', 'string', 'The name of this body.'),
    Register::Field.new('country', 'curie', 'Code of the country that this body is based in.'), #TODO desc
    Register::Field.new('address', 'string', 'The address the body is based at.'),
    Register::Field.new('phone', 'string', 'A phone number on which the body can receive calls.'),
    Register::Field.new('fax', 'string', 'A phone number on which the body can receive faxes.'),
    Register::Field.new('email', 'string', 'An e-mail address at which the body can receive mail.'),
    Register::Field.new('website', 'string', 'URL of a website describing the body.'), #TODO type
    Register::Field.new('products', 'curie', 'Product types the body is accredited to handle.', 'n'), #TODO desc
    Register::Field.new('annexes', 'curie', 'Annexes containing the procedures that the body is accredited to carry out.', 'n') #TODO desc
  )
  bodies.custodian = 'Simon Worthington'

  bodies_nav_page = page nando('notifiedbody.main')
  bodies_nav_page.css('#main_content table table td img + a.list').each do |bodies_page_link|
    bodies_page = page nando_rel_link(bodies_page_link.attribute('href').value)
    bodies_page.css('#main_content table tr:nth-child(6) table tr:not(:first-child)').each_with_index do |body_row|
      body_info = {}
      body_type, _ = body_row.at_css('td:first-child').text.split(' ')
      body_info[:type] = "body-type:#{body_type.gsub(/[^A-Z]/, '')}" #to handle nbsp

      href = body_row.at_css('a').attribute('href').value
      query_params = URI.parse(href).query.split('&').map {|s| s.split('=')}.to_h
      body_info[:body] = URI.decode(query_params['refe_cd'])

      # First look through the body page and pull out the contact information
      body_page = page nando_rel_link(href)
      body_page.at_css('#main_content > table > tr:nth-child(3) > td:nth-child(2)').children.each do |c|
        case c
        when Nokogiri::XML::Element
          body_info[:name] ||= c.text if c.name == 'strong'
        when Nokogiri::XML::Text
          name_or_value, maybe_value = c.text.split(':', 2)
          if ['Country', 'Phone', 'Fax', 'Email', 'Website', 'Notified Body number'].include? name_or_value.strip
            name = name_or_value.strip.downcase.gsub(' ', '-').to_sym
            value = maybe_value.strip
            body_info[name] = value if value != '' && value != '-'
          elsif ['Body', 'Last update'].include? name_or_value.strip
            next
          elsif c.text.strip != ''
            # Address line
            body_info[:address] = (body_info[:address] || '') + c.text.strip + "\n"
          end
        end
      end

      # Now look at all the legislations this body is notified for
      body_page.css('#main_content table table tr:not(:first-child)').each do |legislation_row|
        href = legislation_row.at_xpath('.//a[text() = "HTML"]').attribute('href').value
        legislation_id, _ = parse_legislation_text legislation_row.at_css('td:nth-child(1)').text
        next if legislation_id == 'Regulation (EU) No 305/2011' # skip construction products for now

        legislation_page = page nando_rel_link(href)
        last_top_product = nil
        legislation_page.at_css('#main_content table table table tr:not(:first-child) td:first-child').children.each do |c|
          next unless c.is_a? Nokogiri::XML::Text
          description = c.text.gsub(/^(#{WHITESPACE_WITH_NBSP})+/, '').gsub(/(#{WHITESPACE_WITH_NBSP})+$/, '')
          next unless description != ''
          subproduct = description.start_with?('-')
          description = subproduct ? description[2..-1] : description
          parent = subproduct ? last_top_product : nil
          begin
            product = find_or_add_product.call legislation_id, description, parent
          rescue Exception => e
            STDERR.puts e
            next
          end
          body_info[:products] = (body_info[:products] || []).push "product:#{product[:product]}"
          last_top_product = product[:product] unless subproduct
        end

        procedure_cells = legislation_page.at_css('#main_content table table table tr:not(:first-child) td:nth-child(2)').children
        annex_cells = legislation_page.at_css('#main_content table table table tr:not(:first-child) td:nth-child(3)').children
        found_annexes = procedure_cells.zip(annex_cells).reduce({}) do |hash, (procedure_description, annex)|
          raise 'Looks like procedures and annexes are not 1-1 after all' unless annex.class == procedure_description.class
          next hash unless annex.is_a? Nokogiri::XML::Text
          next hash unless annex.text.strip != ''
          hash[annex.text.strip] = (hash[annex.text.strip] || []).push procedure_description.text.strip
          hash
        end

        body_info[:annexes] = found_annexes.map do |annex, procedures|
          annex = find_or_add_annex.call legislation_id, annex, procedures
          "annex:#{annex[:annex]}"
        end
      end

      bodies.append_entry :user, body_info[:body], body_info
      progress bodies.items.size, 2900
    end
  end

  [products, annexes, bodies].each do |register|
    primary_index = register.indexes[register.name.to_sym]
    multi_keys = primary_index.keys.select {|k| primary_index[k].size > 1 }
    multi_keys.each do |key|
      warn "Register '#{register.name}' contains multiple items for key '#{key}'"
    end
  end

  products.finish!
  annexes.finish!
  bodies.finish!
  orc.close
  products.to_rsf 'products.rsf'
  annexes.to_rsf 'annexes.rsf'
  bodies.to_rsf 'bodies.rsf'
end

file 'product.rsf' => 'body.rsf'
file 'annex.rsf' => 'body.rsf'

file 'body-type.rsf' do |t|
  orc = Orc.new STORE
  body_types = Register.new orc
  body_types.init(
    'body-type',
    'European-Commission',
    'Types of body defined by NANDO.',
    Register::Field.new('body-type', 'string', 'Unique abbreviation representing the type of the body.'),
    Register::Field.new('name', 'string', 'Full name of the body type.'),
    Register::Field.new('definition', 'string', 'Characteristic that a body has to have to be this type.')
  )
  body_types.custodian = 'Simon Worthington'

  body_types.append_entry :user, "CAB",  {'body-type': "CAB",  name: "Conformity Assessment Body", definition: "A body that performs one or several elements of conformity assessment, including one or several of the following activities: calibration, testing, certification and inspection."}
  body_types.append_entry :user, "NB",   {'body-type': "NB",   name: "Notified Body", definition: "A conformity assessment body officially designated by the national authority to carry out the procedures for conformity assessment within the meaning of applicable Union harmonisation legislation."}
  body_types.append_entry :user, "TAB",  {'body-type': "TAB",  name: "Technical Assessment Body", definition: "An organisation that has been designated by a Member State as being entrusted with the establishment of draft European Assessment Documents and the issuing of European Technical Assessments in accordance with the Construction Products Regulation (EU) No 305/ 2011 (CPR)."}
  body_types.append_entry :user, "UI",   {'body-type': "UI",   name: "User Inspectorate", definition: "A conformity assessment body notified to carry out the tasks set out in Article 16 of Directive 2014/68/EU on Pressure Equipment (PED)."}
  body_types.append_entry :user, "RTPO", {'body-type': "RTPO", name: "Recognised Third Party Organisation", definition: "A conformity assessment body notified to carry out the tasks set out in Article 20 of Directive 2014/68/EU on Pressure Equipment (PED)."}

  body_types.finish!
  orc.close
  body_types.to_rsf t.name
end

file STORE => RSFs
