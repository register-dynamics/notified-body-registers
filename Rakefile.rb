require 'open-uri'
require 'nokogiri'
require 'base64'
require_relative 'register'

DIRECTIVE_CODE = /\d+\/\d+(\/[A-Z]+)?/

RSFs = FileList[
  'legislation.rsf',
  'product.rsf',
  'procedure.rsf',
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

def page href
  filename = File.join CACHE, "#{Base64.urlsafe_encode64(href, padding: false)}.html"
  unless File.exist? filename
    rake_output_message "GET #{href}"
    File.write filename, open(href, &:read)
  end

  rake_output_message "#{href} -> #{filename}"
  open(filename, &Nokogiri.method(:HTML))
end

def parse_legislation_text text
  words, code, name = text.strip.partition(DIRECTIVE_CODE)
  legislation_id = words + code
  [legislation_id, name]
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
  legislation = Register.new t.name
  legislation.init(
    'legislation',
    'european-commission',
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
  legislation.close
end

task :read_legislation_pages do
  products = Register.new 'product.rsf'
  products.init(
    'product',
    'european-commission',
    'Products covered by a particular EU product Directive/Regulation.',
    Register::Field.new('product', 'integer', 'The NANDO unique identifier for these products.', 1),
    Register::Field.new('legislation', 'curie', 'The item of EU legislation that covers the products.', 1),
    Register::Field.new('description', 'string', 'Description of product types covered.', 1)
  )
  products.custodian = 'Simon Worthington'

  procedures = Register.new 'procedure.rsf'
  procedures.init(
    'procedure',
    'european-commission',
    'Conformity assessment procedure as set out in Annex II of Decision 758/2008/EC, and in the relevant EU product legislation',
    Register::Field.new('procedure', 'integer', 'The NANDO unique identifier for this procedure.'),
    Register::Field.new('legislation', 'curie', 'The item of EU legislation that includes the procedure.'),
    Register::Field.new('annexes', 'string', 'Annex or Article of the Directive/Regulation which is the source of the procedure.'),
    Register::Field.new('description', 'string', 'Summary of what activity the procedure defines.')
  )
  procedures.custodian = 'Simon Worthington'

  bodies = Register.new 'body.rsf'
  bodies.init(
    'body',
    'european-commission',
    '',
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
    Register::Field.new('products', 'string', 'Product types the body is accredited to handle.'), #TODO desc
    Register::Field.new('procedures', 'string', 'Procedures the body is accredited to carry out.') #TODO desc
  )
  bodies.custodian = 'Simon Worthington'

  legislation_page = page nando('directive.main')
  legislation_page.css('#main_content table table tr').each do |legislation_row|
    link = legislation_row.css('a').first
    text = link.text.strip
    href = link.attribute 'href'
    legislation_id, _ = parse_legislation_text text

    listing_page = page nando_rel_link(href)
    listing_page.css('table table select[name="pro_id"] option').each do |option|
      next if option.text.strip == 'ALL'
      id = option.attribute('value').value.to_i

      products.append_entry :user, id, {
        product: id,
        legislation: "legislation:#{legislation_id}",
        description: option.text.strip
      }
    end

    listing_page.css('table table select[name="prc_anx"] option').each do |option|
      next if option.text.strip == 'ALL'
      id = option.attribute('value').value.to_i
      description, annexes = option.text.split('/')
      annexes ||= ''

      procedures.append_entry :user, id, {
        procedure: id,
        legislation: "legislation:#{legislation_id}",
        description: description.strip,
        annexes: annexes.strip
      }
    end
  end

  bodies_nav_page = page nando('notifiedbody.main')
  bodies_nav_page.css('#main_content table table td img + a.list').each do |bodies_page_link|
    bodies_page = page nando_rel_link(bodies_page_link.attribute('href').value)
    bodies_page.css('#main_content table tr:nth-child(6) table tr:not(:first-child)').each do |body_row|
      body_info = {}
      body_type, _ = body_row.at_css('td:first-child').text.split(' ')
      body_info[:type] = "body-type:#{body_type.gsub(/[^A-Z]/, '')}" #to handle nbsp

      href = body_row.at_css('a').attribute('href').value
      query_params = URI.parse(href).query.split('&').map {|s| s.split('=')}.to_h
      body_info[:body] = query_params['refe_cd']
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
            body_info[:address] = (body_info[:address] || '') + "\n" + c.text.strip
          end
        end
      end

      body_page.css('#main_content table table tr:not(:first-child)').each do |legislation_row|
        href = legislation_row.at_css('td:nth-child(2) a').attribute('href').value
        legislation_id, _ = parse_legislation_text legislation_row.at_css('td:nth-child(1)').text
        next if legislation_id == 'Regulation (EU) No 305/2011' # skip construction products for now

        legislation_page = page nando_rel_link(href)
        legislation_page.at_css('#main_content table table table tr:not(:first-child) td:first-child').children.each do |c|
          next unless c.is_a? Nokogiri::XML::Text
          product = products.items.find {|p| p[:description] == c.text.strip }
          if product.nil?
            STDERR.puts "Product not found? #{c.text.strip}"
          else
            body_info[:products] = (body_info[:products] || "") + "product:#{product[:product]};"
          end
        end

        procedure_cells = legislation_page.at_css('#main_content table table table tr:not(:first-child) td:nth-child(2)').children
        annex_cells = legislation_page.at_css('#main_content table table table tr:not(:first-child) td:nth-child(3)').children
        procedure_cells.zip(annex_cells).each do |procedure_description, annex|
          raise unless annex.class == procedure_description.class
          next unless procedure_description.is_a? Nokogiri::XML::Text
          procedure = procedures.items.find {|p| p[:description] == procedure_description.text.strip && p[:annexes] == annex.text.strip }
          if procedure.nil?
            STDERR.puts "Procedure not found? #{procedure_description.text.strip} / #{annex.text.strip}"
          else
            body_info[:procedures] = (body_info[:procedures] || "") + "procedure:#{procedure[:procedure]};"
          end
        end
      end

      bodies.append_entry :user, body_info[:id], body_info
    end
  end

  products.close
  procedures.close
  bodies.close
end

file 'product.rsf' => :read_legislation_pages
file 'procedure.rsf' => :read_legislation_pages
file 'body.rsf' => :read_legislation_pages

file 'body-type.rsf' do |t|
  body_types = Register.new t.name
  body_types.init(
    'body-type',
    'european-commission',
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
end

file STORE => RSFs do |t|
  RSFs.each do |rsf|
    sh ["orc", "-S", t.name, "digest", rsf].join(" ")
  end
end