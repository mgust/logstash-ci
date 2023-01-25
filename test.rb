#!/usr/bin/ruby

require 'yaml'
require 'json'
require 'open3'
require 'tempfile'
require 'socket'
require 'net/http'
require 'timeout'
require 'optparse'
require_relative 'lib/logstash_test'
require_relative 'lib/logstash_io'

# Retrieve all pipelines from the configuration
def get_pipelines(options)
  pipelines = {}

  pipe_conf = YAML::load_file(options[:config].to_path+"/pipelines.yml")

  # Open each pipeline directory, read all the config files in-order
  pipe_conf.each do |pipe_dir|
    dir = Dir.open(File.join(options[:pipelines], pipe_dir["path.config"].delete_prefix(options[:pipelines_prefix])))
    files = dir.entries.sort.select do |f|
      f.end_with? ".conf" and File.file? File.join(dir.path,f) 
    end 
    
    pipelines[pipe_dir["pipeline.id"]] = files.map do |f|
      fd=File.open(File.join(dir.path,f))
      fd.read
    end.join("\n")
  end

  return pipelines
end

# Take a pipeline and change all marked inputs and outputs into
# tcp ones managed by the Logstash_io class
def transform_testable(pipeline,log_io)
  # tokens
  token_matcher = /
  { | }       # braces
  | => |      # assignment
  '.*' |      # single-quoted strings
  ".*" |      # double-quoted strings
  [^='"\s]+ | # All non-space except ='" (to break on the right boundaries)
  = | ' | "   # to ensure the characters are still captured
  /x

  # find replacement locations
  io_matcher = /(###INPUT###.*?###END###)|(###OUTPUT###.*?###END###)/m
    return pipeline.gsub(io_matcher) do |io|
    tokens = io.scan(token_matcher)

    id_idx = tokens.index { |x| x == "id" }
    if id_idx.nil? then
      raise KeyError.new("Config segment doesn't have an \"id\" parameter set!\n#{io}")
    end
    id = tokens[id_idx + 2].gsub!(/"|'\(.*\)"|'/,'\1')

    if /^###INPUT###/ =~ io then
      # Change all inputs into HTTP inputs (to ensure we get status codes wether it was accepted or not)
      "http { id => \"#{id}\" port => \"#{log_io.new_input(id)}\" codec => \"json\" remote_host_target_field => \"ignore_and_delete_host\" request_headers_target_field => \"ignore_and_delete_headers\" }"
    elsif /^###OUTPUT###/ =~ io then
      # Change all outputs into tcp outputs (no need for HTTP, we don't need status codes)
      "tcp { id => \"#{id}\" host => \"0.0.0.0\" port => \"#{log_io.new_output(id)}\" mode => \"server\" codec => \"json_lines\" }"
    else
      # This should never happen, we are matching on a regexp after all
      raise KeyError.new("Neither an INPUT or OUTPUT segment?\n#{io}")
    end
  end
end

# Reads and parses all tests in the test directory
def read_tests(options)
  tests = []
  io_matcher = /(###INPUT-(\S+)###([^###]+))|(###OUTPUT-(\S+)###([^###]+))|(###END###)/m
  options[:tests].entries.each do |test|
    file = File.join(options[:tests],test)
    if File.file? file then
      current = nil
      File.open(file).read.scan(io_matcher) do |block|
        if not block[0].nil? then
          tests << current unless current.nil?
          current = Logstash_test.new(file,block[1], JSON.parse(block[2]))
          # output block
        elsif not block[3].nil? then
          if current.nil? then
            raise KeyError.new("Output block encountered before INPUT block in #{file}!")
          end
          current.add_output(block[4],JSON.parse(block[5]))
        else
          raise RuntimeError.new("Unable to parse part of #{file} (#{block})")
        end
      end
      tests << current unless current.nil?
    end
  end
  return tests
end

# A non-blocking reader of stdin/stdout from Logstash
def print_proc(stdout,stderr)
  begin
    puts stdout.read_nonblock 1024
  rescue IO::WaitReadable,EOFError
  end
  begin
    STDERR.puts stderr.read_nonblock 1024
  rescue IO::WaitReadable,EOFError
  end
end

# The thread running the above print_proc to ensure we don't have to
# keep interleaving it with all other code
def print_proc_thread(stdout,stderr)
  begin
    while true
      IO.select([stdout,stderr])
      print_proc(stdout,stderr)
    end
  rescue
    STDERR.puts "Dropped stdin/stdout connection to Logstash docker container"
  end
end

def is_pipeline_ready(stats, name)
  pipeline = stats['pipelines'][name]
  return false unless pipeline
  return pipeline['reloads'] != nil
end


def main(options)

  # Ensure we don't use the TMPDIR as that might cause issues with
  # docker running on a laptop where you can only share directories in ~
  ENV['TMPDIR']=Dir.pwd

  Dir.mktmpdir do |tmpdir|
    Dir.mkdir(File.join(tmpdir,"pipelines"))
    pipelines = get_pipelines(options)

    io = Logstash_io.new
    pipelines.each do |name,conf|
      File.open(File.join(tmpdir,"pipelines",name),"w") do |fd|
        c = transform_testable(conf,io)
        fd.write c
      end
    end

    # Create default logstash.yml
    File.open(File.join(tmpdir,"logstash-cnf.yml"),"w") do |fd|
      fd.write <<-EOF
        config.reload.automatic: false
        http.host: 0.0.0.0
        log.level: error
        pipeline.workers: 1
        pipeline.ecs_compatibility: disabled
      EOF
    end

    # Write out pipelines.yml
    File.open(File.join(tmpdir,"pipelines.yml"),"w") do |fd|
      pipelines.each do |name,conf|
        fd.write <<-EOF
        - pipeline.id: #{name}
          pipeline.workers: 1
          path.config: /usr/share/logstash/pipeline/#{name}
          config.reload.automatic: false
        EOF
      end

      fd.write <<-EOF
        - pipeline.id: logstash-test-pipeline.yml
          pipeline.workers: 1
          path.config: /usr/share/logstash/pipeline/logstash-test-pipeline.yml
          config.reload.automatic: false
      EOF
    end

    tests = read_tests(options)

    tests.each { |x| exit -2 unless x.verify_channels(io) }

    Open3.popen3("docker run #{io.to_s} --name=logstash-tests --rm -v #{File.join(tmpdir, "logstash-cnf.yml")}:/usr/share/logstash/config/logstash.yml -v #{File.join(tmpdir, "pipelines.yml")}:/usr/share/logstash/config/pipelines.yml -v #{File.join(tmpdir,"pipelines")}:/usr/share/logstash/pipeline -p 9600:9600 #{options[:image]}") do |stdin, stdout, stderr, status_thread|
      puts "** Logstash starting, waiting for it to come online **"
      begin
        ret = 0

        # Ensure we keep printing logstash output in the background
        docker_output = Thread.new { print_proc_thread(stdout,stderr) }

        # If we can get a response from the pipelines API, we are ready to run tests
        # ... though we may need to wait for Docker to download the image first
        # and that can take a while, so be patient
        monitoring_uri = URI("http://localhost:9600/_node/stats/pipelines")
        logstash_ready = false
        count = 0
        max_attempts = 300
        while count < max_attempts
          begin
            response = Net::HTTP.start(monitoring_uri.host, monitoring_uri.port) {|http|
              request = Net::HTTP::Get.new monitoring_uri
              http.request request
            }
            if response.code == "200" then
              response_payload = JSON.parse(response.body)

              if pipelines.keys.all? { |name| is_pipeline_ready(response_payload, name) }
                puts "********** Logstash pipelines have started! **********"
                logstash_ready = true
                break
              else
                puts "********** Waiting for pipelines to start... **********"
              end
            else
                puts "********** Waiting for monitoring API to become available... **********"
            end
          rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError
            # These errors can happen while API is not ready to serve responses
          end
          count += 1
          sleep 1
        end

        if logstash_ready then
          puts "********** Connecting to TCP sockets and running all tests *********"
          # Connect to all tcp sockets
          io.connect
          # Do all the tests
          tests.each do |test|
            ret = 1 unless test.test(io,tmpdir)
          end
          # Terminate Logstash nicely
          stdin.close
          Process.kill("TERM",status_thread.pid)
          puts "*** all sent, awaiting logstash to finish ***"
          io.disconnect_outputs
          status_thread.join
          Thread.kill(docker_output)
          exit ret
        end
      rescue => e
        begin
          # Ensure we terminate logstash so we don't just hang in case
          # something goes wrong
          stdin.close unless stdin.closed?
          Process.kill("TERM",status_thread.pid)
          puts "*** shutting down logstash ***"
          io.disconnect_outputs
          status_thread.join
        rescue => ignore
          # Exception handler to the exception handler ;)
          puts "Exception handler failed, you may need to force terminate with CTRL-c"
          puts ignore
        ensure
          Thread.kill(docker_output) unless docker_output.nil?
        end
        raise e
      end
      puts "\e[32mFailed during startup!\e[0m"
      print_proc(stdout,stderr)
      exit -1
    end
  end
end

options = { :image => "logstash:8.6.0", 
            :root => "/usr/share/logstash",
            :pipelines_prefix => "/usr/share/logstash/pipeline" 
}

optparse = OptionParser.new do |opts|
  opts.banner = "Usage: test.rb [options]"

  opts.on("-i", "--image", "Docker image containing Logstash (default logstash:8.6.0") do |v|
    options[:image] = v
  end

  opts.on("-cDIRECTORY", "--config DIRECTORY", "Logstash configuration directory <required>") do |v|
    options[:config] = Dir.open(v) 
  end

  opts.on("-tDIRECTORY", "--tests DIRECTORY", "Directory containing the tests to run <required>") do |v|
    options[:tests] = Dir.open(v)
  end

  opts.on("--pipelines_prefix DIRECTORY", "Path prefix to remove from the pipelines (default /usr/share/logstash/pipeline)") do |v|
    options[:pipelines_prefix] = v
  end

  opts.on("-pDIRECTORY", "--pipelines DIRECTORY", "Directory containing the pipelines <required>") do |v|
    options[:pipelines] = v
  end

end

optparse.parse!

if options[:pipelines].nil? or options[:config].nil? or options[:tests].nil? then
  abort(optparse.help)
end

main(options)
