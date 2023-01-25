# To keep track of the inputs/outputs to the Logstash docker instance
# TODO the port assignment is entirely random and _can_ clash
class Logstash_io
  attr_reader :inputs,:outputs

  def initialize
    @inputs = {}
    @outputs = {}
    # This probably should take into account which ports are available instead of presuming them all to be clear
    @port = 3200 + Random.rand(3200)
  end

  def new_input(id)
    port = self.get_port
    @inputs[id] = port
    return port
  end

  def new_output(id)
    port = self.get_port
    @outputs[id] = port
    return port
  end

  # Generates a port string suitable for docker
  # (-p 3200:3200 -p 3201:3201 et.c)
  def to_s
    ports = []
    @inputs.each do |id,port|
      ports << "-p #{port}:#{port}"
    end
    @outputs.each do |id,port|
      ports << "-p #{port}:#{port}"
    end
    return ports.join(" ")
  end

  # Find the ID of the filedescriptor
  def get_output_id(fd)
    @outputs.find { |id,conn| conn == fd }[0]
  end

  # Connect all inputs and outputs
  def connect
    @inputs.each do |id,port|
      begin
        @inputs[id] = Net::HTTP.new 'localhost', port
        @inputs[id].read_timeout = 10
      rescue Exception => e
        raise $!, "Input #{id}: #{$!}", $!.backtrace
      end
    end
    @outputs.each do |id,port|
      begin
        @outputs[id] = TCPSocket.new 'localhost', port
      rescue Exception => e
        raise $!, "Output #{id}: #{$!}", $!.backtrace
      end
    end
  end

  def disconnect_outputs
    @outputs.each do |id,tcp|
      tcp.close
    end
  end

  protected
  # Get the next "available" port
  def get_port
    @port = @port.succ
  end
end

