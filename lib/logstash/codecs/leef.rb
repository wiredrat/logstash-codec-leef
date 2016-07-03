# encoding: utf-8
require "logstash/codecs/base"
require "json"

# Implementation of a Logstash codec for the qRADAR Log Event Extended Format (LEEF)
# Based on Version 1.0 of Implementing QRadar LEEF.
# https://www.ibm.com/developerworks/community/wikis/form/anonymous/api/wiki/9989d3d7-02c1-444e-92be-576b33d2f2be/page/3dc63f46-4a33-4e0b-98bf-4e55b74e556b/attachment/a19b9122-5940-4c89-ba3e-4b4fc25e2328/media/QRadar_LEEF_Format_Guide.pdf
 
class LogStash::Codecs::LEEF < LogStash::Codecs::Base
  config_name "leef"

  # Device vendor field in LEEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :vendor, :validate => :string, :default => "Elastic"

  # Device product field in LEEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :product, :validate => :string, :default => "Logstash"

  # Device version field in LEEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :version, :validate => :string, :default => "2.3.3"

  # EventID field in LEEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :eventid, :validate => :string, :default => "Logstash"

  # Name field in LEEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  #config :name, :validate => :string, :default => "Logstash"

  # Deprecated severity field for LEEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  #
  # This field is used only if :severity is unchanged set to the default value.
  #
  # Defined as field of type string to allow sprintf. The value will be validated
  # to be an integer in the range from 0 to 10 (including).
  # All invalid values will be mapped to the default of 6.
  #config :sev, :validate => :string, :default => "6", :deprecated => "This setting is being deprecated, use :severity instead."

  # Severity field in LEEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  #
  # Defined as field of type string to allow sprintf. The value will be validated
  # to be an integer in the range from 0 to 10 (including).
  # All invalid values will be mapped to the default of 6.
  #config :severity, :validate => :string, :default => "6"

  # Fields to be included in LEEF extension part as key/value pairs
  config :fields, :validate => :array, :default => []

  public
  def initialize(params={})
    super(params)
  end

  public
  def decode(data)
    # Strip any quotations at the start and end, flex connectors seem to send this
    if data[0] == "\""
      data = data[1..-2]
    end
    event = LogStash::Event.new

    # Split by the pipes, pipes in the extension part are perfectly valid and do not need escaping
    # The better solution for the splitting regex would be /(?<!\\(\\\\)*)[\|]/, but this
    # gives an "SyntaxError: (RegexpError) invalid pattern in look-behind" for the variable length look behind.
    # Therefore one edge case is not handled properly: \\| (this should split, but it does not, because the escaped \ is not recognized)
    # TODO: To solve all unescaping cases, regex is not suitable. A little parse should be written.
    event['leef_version'], event['leef_vendor'], event['leef_product'], event['leef_device_version'], event['leef_eventid'], *message = data.split /(?<=[^\\]\\\\)[\|]|(?<!\\)[\|]/
    message = message.join('|')

    # Unescape pipes and backslash in header fields
    event['leef_version'] = event['leef_version'].gsub(/\\\|/, '|').gsub(/\\\\/, '\\')
    event['leef_vendor'] = event['leef_vendor'].gsub(/\\\|/, '|').gsub(/\\\\/, '\\')
    event['leef_product'] = event['leef_product'].gsub(/\\\|/, '|').gsub(/\\\\/, '\\')
    event['leef_device_version'] = event['leef_device_version'].gsub(/\\\|/, '|').gsub(/\\\\/, '\\')
    event['leef_eventid'] = event['leef_eventid'].gsub(/\\\|/, '|').gsub(/\\\\/, '\\')
    #event['leef_name'] = event['leef_name'].gsub(/\\\|/, '|').gsub(/\\\\/, '\\')
    #event['leef_severity'] = event['leef_severity'].gsub(/\\\|/, '|').gsub(/\\\\/, '\\') unless event['leef_severity'].nil?

    # Try and parse out the syslog header if there is one
    if event['leef_version'].include? ' '
      event['syslog'], unused, event['leef_version'] = event['leef_version'].rpartition(' ')
    end

    # Get rid of the LEEF bit in the version
    event['leef_version'] = event['leef_version'].sub /^LEEF:/, ''

    # Strip any whitespace from the message
    if not message.nil? and message.include? '='
      message = message.strip

      # If the last KVP has no value, add an empty string, this prevents hash errors below
      if message.end_with?('=')
        message=message + ' ' unless message.end_with?('\=')
      end

      # Now parse the key value pairs into it
      extensions = {}
      message = message.split(/ ([\w\.]+)=/)
      key, value = message.shift.split('=', 2)
      extensions[key] = value.gsub(/\\=/, '=').gsub(/\\\\/, '\\')

      Hash[*message].each{ |k, v| extensions[k] = v }

      # And save the new has as the extensions
      event['leef_ext'] = extensions
    end

    yield event
  end

  public
  def encode(event)
    # "LEEF:1.0|Elastic|Logstash|2.3.3|EventID|"

    vendor = sanitize_header_field(event.sprintf(@vendor))
    vendor = self.class.get_config["vendor"][:default] if vendor == ""

    product = sanitize_header_field(event.sprintf(@product))
    product = self.class.get_config["product"][:default] if product == ""

    version = sanitize_header_field(event.sprintf(@version))
    version = self.class.get_config["version"][:default] if version == ""

    eventid = sanitize_header_field(event.sprintf(@eventid))
    eventid = self.class.get_config["eventid"][:default] if eventid == ""

    #name = sanitize_header_field(event.sprintf(@name))
    #name = self.class.get_config["name"][:default] if name == ""

    # :sev is deprecated and therefore only considered if :severity equals the default setting or is invalid
    #severity = sanitize_severity(event, @severity)
    #if severity == self.class.get_config["severity"][:default]
      # Use deprecated setting sev
     # severity = sanitize_severity(event, @sev)
   # end

    # Should also probably set the fields sent
    header = ["LEEF:1.0", vendor, product, version, eventid].join("|")
    values = @fields.map {|fieldname| get_value(fieldname, event)}.compact.join("	")

    @on_event.call(event, "#{header}|#{values}\n")
  end

  private

  # Escape pipes and backslashes in the header. Equal signs are ok.
  # Newlines are forbidden.
  def sanitize_header_field(value)
    output = ""

    value = value.to_s.gsub(/\r\n/, "\n")

    value.each_char{|c|
      case c
      when "\\", "|"
        output += "\\" + c
      when "\n", "\r"
        output += " "
      else
        output += c
      end
    }

    return output
  end

  # Keys must be made up of a single word, with no spaces
  # must be alphanumeric
  def sanitize_extension_key(value)
    value = value.to_s.gsub(/[^a-zA-Z0-9]/, "")
    return value
  end

  # Escape equal signs in the extensions. Canonicalize newlines.
  # LEEF spec leaves it up to us to choose \r or \n for newline.
  # We choose \n as the default.
  def sanitize_extension_val(value)
    output = ""

    value = value.to_s.gsub(/\r\n/, "\n")

    value.each_char{|c|
      case c
      when "\\", "="
        output += "\\" + c
      when "\n", "\r"
        output += "\\n"
      else
        output += c
      end
    }

    return output
  end

  def get_value(fieldname, event)
    val = event[fieldname]

    return nil if val.nil?

    case val
    when Array, Hash
      return "#{sanitize_extension_key(fieldname)}=#{sanitize_extension_val(val.to_json)}"
    when LogStash::Timestamp
      return "#{sanitize_extension_key(fieldname)}=#{val.to_s}"
    else
      return "#{sanitize_extension_key(fieldname)}=#{sanitize_extension_val(val)}"
    end
  end

  #def sanitize_severity(event, severity)
  #  severity = sanitize_header_field(event.sprintf(severity)).strip
  #  severity = self.class.get_config["severity"][:default] unless valid_severity?(severity)
  #  severity = severity.to_i.to_s
  #end

  #def valid_severity?(sev)
  #  f = Float(sev)
    # check if it's an integer or a float with no remainder
    # and if the value is between 0 and 10 (inclusive)
  #  (f % 1 == 0) && f.between?(0,10)
  #rescue TypeError, ArgumentError
  #  false
  #end

end
