require 'timeout'
require_relative 'jsondiff'

# Class to hold all tests
class Logstash_test
  attr_accessor :name

  def initialize(name,input_id,input_json)
    @input = {input_id => input_json }
    @outputs = {}
    @name = name
  end

  def add_output(output_id,output)
    # TODO We need a generic way of ignoring certain fields.
    if output.has_key? "geoip" or  output.has_key? "ignore_and_delete_host" or output.has_key? "ignore_and_delete_headers" or output.has_key? "@timestamp" or output.has_key? "time" or output.has_key? "@version"  then
      STDERR.puts "\e[31m****** WARNING *****\e[0m"
      STDERR.puts "Your test output in #{@name} contains the field 'geoip' or 'ignore_and_delete_host' or 'ignore_and_delete_headers' or or 'time' or '@timestamp' '@version' which is filtered to deal with added fields by the http input."
      STDERR.puts "The tests will fail"
    end
    @outputs[output_id] = output
  end

  def verify_channels(io)
    @outputs.keys.each do |key|
      unless io.outputs.has_key? key
        STDERR.puts "#{@name} has output ID #{key} is not available in the configuration!"
        return false
      end
    end
    @input.keys.each do |key|
      unless io.inputs.has_key? key
       STDERR.puts "#{@name} has input ID #{key} that is not available in the configration!"
       return false
     end
    end
   return true
  end

  # Cleans out attributes that are either inconsistent
  # or added by the testing process
  def clean_attributes(json)
    # remove the headers that are added by the http input
    json.delete("ignore_and_delete_headers")
    json.delete("ignore_and_delete_host")

    # Delete default field
    json.delete("@version")

    # Temporary hack, the geoip changes based on the database used :(
    json.delete("geoip")

    if json.has_key? "data" and json["data"].has_key? "tags" then
      # Hack to fix this issue https://github.com/elastic/logstash/issues/6184
      json["data"]["tags"]=json["data"]["tags"].uniq
      # Hack to ignore routing tags
      json["data"]["tags"] = json["data"]["tags"].reject! { |tag| /^(_input|_route|filebeat)-/.match(tag) }
    elsif json.has_key? "tags" then
      # Hack to fix this issue https://github.com/elastic/logstash/issues/6184
      json["tags"]=json["tags"].uniq
      # Hack to ignore routing tags
      json["tags"].reject! { |tag| /^(_input|_route|filebeat)-/.match(tag) }
    end


    # Can't compare timestamps, they'll always be different
    json.delete("@timestamp")
    return json
  end

  # Run the test with the supplied Logstash_io connections
  def test(io,tmpdir)
    if io.inputs[@input.first[0]].nil? then
      raise KeyError.new("In #{@name}: unable to find input with id #{@input.first[0]} in Logstash config!\nInputs configured: #{io.inputs.keys.join(',')}")
    end
    count = 0
    while count < 30
      begin 
        response = io.inputs[@input.first[0]].post("/", @input.first[1].to_json, {"Content-Type": "application/json"})
        if response.code =~ /^2..$/ then
          break
        else
          puts "Got bad response from Logstash #{response.code}"
        end
      rescue EOFError,Errno::EPIPE,Errno::ECONNRESET,Net::ReadTimeout
      end
      count = count.succ
      # We need a retry because Logstash seems to always fail the first request
      puts "Retrying in 1 sec (attempt #{count})"
      sleep 1
    end
    if count == 30
      raise Exception.new("Unable to get successful response from Logstash, terminating!")
    end
    ret = true

    # Timeout of 15 seconds until giving up waiting for more data
    end_time = Time.now + 15

    # List of all outputs we are still expecting to arrive
    pending_outputs = @outputs.clone

    while not pending_outputs.empty? and end_time > Time.now

      pending_data = IO.select(io.outputs.values,nil,nil,15)

      if pending_data.nil?
        pending_data = [] 
        puts "Received nothing after #{Time.now - (end_time - 15)} seconds"
      else
        pending_data = pending_data[0]
      end
      pending_data.each do |fd|
        begin
          pending_id = io.get_output_id(fd)
          # Non-blocking read to not get hung if there is no trailing newline
          read = io.outputs[pending_id].read_nonblock 4096

          json = JSON.parse(read)

          json = clean_attributes(json)

          # Compare the output with the expected output
          src = recurse_sorted(@outputs[pending_id])
          actual = recurse_sorted(json)
          if src == actual then
            # Both strings matched, great success
            puts "\e[32mTest #{@name}(#{pending_id}) passed!\e[0m"
            pending_outputs.delete pending_id
          else
            # The strings aren't the same, call out to `diff` for actual comparison
            # output
            puts "\e[31mTest #{@name}(#{pending_id}) failed!\e[0m"
            File.open(File.join(tmpdir,"expected.json"),"w") { |fd| fd.write(src) }
            File.open(File.join(tmpdir,"actual.json"),"w") { |fd| fd.write(actual) }
            puts "Diff: "
            puts `diff -W 255 -y #{File.join(tmpdir,"expected.json")} #{File.join(tmpdir,"actual.json")}`
            ret = false
            pending_outputs.delete pending_id
          end
        rescue => err
          STDERR.puts "Exception occured whilst reading input"
          STDERR.puts err.backtrace
          STDERR.puts err
          ret = false
          pending_outputs.delete pending_id
        end
      end
    end

    # In case all the outputs are empty, wait 2 seconds for stray output 
    # before saying we are good
    if @outputs.empty? then
      read = IO.select(io.outputs.values,nil,nil,2)
      if read.nil?
        puts "\e[32mTest #{@name} passed!\e[0m"
        return true
      else
        ret = false
        puts "\e[31mTest #{@name} failed!\e[0m"
        puts "Expected no output, however output was available on #{read[0].map { |fd| io.get_output_id fd }.join(',')}"
        read[0].each do |fd|
          puts "---(#{io.get_output_id fd})---"
          begin
            puts fd.read_nonblock 4096
          rescue IO::WaitReadable,EOFError
            puts "<no content>"
          end
        end
      end
    end

    # Finally, are we pending any outputs we never received?
    unless pending_outputs.empty? then
      ret = false
      puts "\e[31mTest #{@name} failed!\e[0m"
      puts "Expected output on #{pending_outputs.keys.join(',')} but nothing was received!"
    end

    return ret
  end

  # Just an easy way to print tests for debugging
  def to_s
    return "---input (#{@input.first[0]})---\n#{@input.first[1]}\n"
  end
end
