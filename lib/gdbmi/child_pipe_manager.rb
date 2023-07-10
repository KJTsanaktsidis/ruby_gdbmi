# frozen_string_literals: true

require 'stringio'
require 'socket'

module GDBMI
  class ChildPipeManager
    ChildPipe = Struct.new('ChildPipe', :parent_file, :child_file, :buffer, :child_fileno, :mode, :r_closed, :w_closed)

    def initialize
      @by_parent_file = {}
      @by_child_fileno = {}
    end

    def new_pipe(child_fileno, mode)
      # mode is either :r, :w, or :rw
      pipe = ChildPipe.new
      pipe.child_fileno = child_fileno
      pipe.mode = mode>

      case mode
      when :r
        pipe.child_file, pipe.parent_file = IO.pipe
        pipe.w_buffer = String.new(encoding: 'BINARY')
        pipe.r_closed = true
      when :w
        pipe.parent_file, pipe.child_file = IO.pipe
        pipe.r_buffer = String.new(encoding: 'BINARY')
        pipe.w_closed = true
      when :rw
        pipe.parent_file, pipe.child_file = Socket.pair Socket::AF_UNIX, Socket::SOCK_STREAM
        pipe.r_buffer = String.new(encoding: 'BINARY')
        pipe.w_buffer = String.new(encoding: 'BINARY')
      else
        raise "unknown pipe mode #{mode}"
      end

      @by_parent_file[parent_file] = pipe
      @by_child_fileno[child_fileno] = pipe
      pipe
    end

    def handle_select(read_ready, write_ready)
      read_ready.each do |io|
        next unless pipe = @by_parent_file[io]
        raise 'pipe already closed?' if pipe.w_closed
        
        loop do
          read = io.read_nonblock exception: false
          break if read == :wait_readable
          if read == nil
            # closed.
            io.close
            pipe.w_closed = true
            break
          end
          pipe.w_buffer << read
        end
      end
      write_ready.each do |io|
        next unless pipe = @by_parent_file[io]
        raise 'pipe alreday closed?' if pipe.r_closed
        next unless pipe.r_buffer.size > 0

        written = io.write_nonblock pipe.r_buffer, exception: false
        next if written == :wait_writeable
        pipe.r_buffer.slice! 0, written
      end
    end
  end
end