# frozen_string_literal: true

require 'shellwords'
require 'rbconfig'
require 'stringio'

module GDBMI
  class Session
    
    GDBState = Struct.new(:params)
    AUTOLOAD_ENABLE_OPTS = %w(
      gdb-scripts libthread-db local-gdbinit python-scripts
    ).freeze
    SUPPORT_PY_FILE = File.absolute_path(File.join(__dir__, 'support.py')).freeze

    def initialize(gdb: 'gdb', verbose: false)
      @gdb_prog = gdb
      @verbose = verbose
      
      @program_stdin_r, @program_stdin_w = IO.pipe
      @program_stdout_r, @program_stdout_w = IO.pipe
      @program_stderr_r, @program_stderr_w = IO.pipe
      @gdbmi_stdin_r, @gdbmi_stdin_w = IO.pipe
      @gdbmi_stdout_r, @gdbmi_stdout_w = IO.pipe
      redirections = {
        # FDs we use to talk to gdb/mi itself
        0 => @gdbmi_stdin_r,
        1 => @gdbmi_stdout_w,
        2 => $stderr,
        # FDs we will bind to the child process
        3 => @program_stdin_r,
        4 => @program_stdout_w,
        5 => @program_stderr_w,
        :close_others => true,
      }
      @program_output_buffers = {
        1 => [@program_stdout_r, StringIO.new],
        2 => [@program_stderr_r, StringIO.new],
      }
      
      # Also bind stdin if it's a TTY, so we can offer "drop to a shell"
      # functionality
      if $stdin.tty?
        @tty = File.readlink("/proc/self/fd/#{$stdin.fileno}")
        redirections[6] = @tty
      end

      # Internal GDB state mirror.
      @token_counter = 0
      @state = GDBState.new
      
      gdb_cmdline = [
        @gdb_prog,
        '--interpreter=mi4', # enable GDB/MI
        '--nh', '--nx', # Don't source .gdbinit
      ]
      @gdb_pid = Process.spawn(*gdb_cmdline, redirections)
      @gdbmi_stdin_r.close
      @gdbmi_stdout_w.close
      
      mi_read_output_block

      # Source our python file
      mi_run_raw_console_command('source', SUPPORT_PY_FILE)
      # Our script which is responsible for actually executing the child
      prepare_wrapper_program
    end
  
    def self.open(*args, **kwargs)
      session = self.new(*args, **kwargs)
      begin
        yield session
      ensure
        session.close
      end
    end
  
    def close
      if @gdb_pid
        Process.kill :TERM, @gdb_pid
        Process.waitpid2 @gdb_pid
      end
      
      @program_stdin_r&.close
      @program_stdin_w&.close
      @program_stdout_r&.close
      @program_stdout_w&.close
      @program_stderr_r&.close
      @program_stderr_w&.close
      @gdbmi_stdin_r&.close
      @gdbmi_stdin_w&.close
      @gdbmi_stdout_r&.close
      @gdbmi_stdout_w&.close
      @wrapper_script&.unlink
    end
  
    ### GDB parameters

    def debuginfod_enabled=(value)
      mi_run_raw_command('-gdb-set', 'debuginfod', 'enabled', bool_to_onoff(value), quote: false)
      value
    end

    def debuginfod_enabled
      r = mi_run_raw_command('-gdb-show', 'debuginfod', 'enabled', quote: false)
      onoff_to_bool r.value['value']
    end
    alias_method :debuginfod_enabled?, :debuginfod_enabled

    def auto_load_enabled=(value)
      if !value
        # You can set auto-load off in one command
        mi_run_raw_command('-gdb-set', 'auto-load', 'off', quote: false)
      else
        # Needs to be set _on_ in several commands
        AUTOLOAD_ENABLE_OPTS.each do |o|
          mi_run_raw_command('-gdb-set', 'auto-load', o, 'on', quote: false)
        end
      end
      value
    end

    def auto_load_enabled
      # Consider auto-load "enabled" if all of the subparts are enabled.
      AUTOLOAD_ENABLE_OPTS.all? do |o|
        r = mi_run_raw_command('-gdb-show', 'auto-load', o, quote: false)
        onoff_to_bool r.value['value']
      end
    end
    alias_method :auto_load_enabled?, :auto_load_enabled

    ### Target management
    
    def file=(value)
      mi_run_raw_command('-file-exec-and-symbols', value)
    end

    def file
      # This is implemented in support.py; there is no equivalent command inside GDB.
      r = mi_run_raw_command('-ruby-mi-get-exec-file')
      v = r.value['value']
      return nil if v == ''
      v
    end

    def arguments=(args)
      args = args.to_a if args.respond_to?(:to_a)
      raise "Session#arguments= must take an array" unless args.is_a?(Array)
      mi_run_raw_command('-exec-arguments', *args)
      args
    end

    def arguments
      r = mi_run_raw_command('-gdb-show', 'args', quote: false)
      quoted_args = r.value['value']
      Shellwords.split(quoted_args)
    end

    ## Execution

    def run
      mi_run_raw_command('-exec-run')
      nil
    end

    def wait_for
      loop do
        break if yield self
        mi_read_output_block
      end
    end


    ### Raw command processing

    def mi_run_raw_console_command(*command, &blk)
      command_string = command.join(' ')
      mi_run_raw_command('-interpreter-exec', 'console', command_string, &blk)
    end

    def mi_run_raw_command(*command, quote: nil, &blk)
      token_val = @token_counter
      @token_counter += 1
      
      kwargs = { token: token_val }
      kwargs[:quote] = quote unless quote.nil?
      command_str = mi_build_command_string(*command, **kwargs)

      mi_log_input_line command_str
      @gdbmi_stdin_w.puts command_str
      loop do
        record = mi_read_output_block(&blk)
        return record if record && record.numtoken == token_val
      end
    end
  
    private
    
    def mi_build_command_string(command_name, *params, token: nil, quote: true)
      arr = [command_name]
      if quote
        arr.concat(params.map { mi_quote _1 })
      else
        arr.concat(params)
      end
      command_str = arr.join(' ')
      if token
        command_str = token.to_s + command_str
      end
      command_str
    end

    def mi_quote(str) = str.dump
    
    
    def mi_read_output_block
      result_record = nil
      loop do
        line = @gdbmi_stdout_r.gets.strip
        mi_log_output_line line
        
        # End of the output block
        break if line == "(gdb)"
        
        record = GDBMI::ResponseParser.new.parse(line)
        mi_update_state record
        yield record if block_given?
        result_record = record if record.record_type == :result
      end
      return result_record
    end

#     def mi_state_machine
#       result_record = nil
#       files = [@gdbmi_stdout_r, *@program_output_buffers.values.map { _1[0] }]
#       gdbmi_output_line = LineBuffer.new
#       loop do
#         rs, _, _ = IO.select(files)
#         rs.each do |pipe|
#           if pipe == @gdbmi_stdout_r
#             r = gdbmi_stdout_r.read_nonblock(exception: false)
#             if r.nil?
#               raise "Unexpected EOF on GDBMI "
#             gdbmi_output_line << @gdbmi_stdout_r.read_nonblock
#         end
#       end
#     end
    
    def mi_log_output_line(line)
      return unless @verbose
      $stderr.puts "GDB/MI -> #{line}"
    end
    
    def mi_log_input_line(line)
      return unless @verbose
      $stderr.puts "GDB/MI <- #{line}"
    end
    
    def mi_update_state(record)
    end

    def bool_to_onoff(bool) = bool ? 'on' : 'off'
    def onoff_to_bool(str)
      case str.strip.downcase
      when 'on'
        true
      when 'off'
        false
      else
        raise "expected 'on' or 'off', got #{str}"
      end
    end

    def prepare_wrapper_program
      child_env = {}
      child_env.merge! ENV unless @clear_env
      child_env.merge! @child_env if @child_env

      @wrapper_script = Tempfile.new(['gdbmi_exec_wrapper', '.rb'])
      @wrapper_script.write <<~RUBY
        #!#{ruby_interpreter_path}
        child_env = Marshal.load(#{Marshal.dump(child_env).dump})
        exec child_env, *ARGV, { 0 => 3, 1 => 4, 2 => 5}
      RUBY
      @wrapper_script.chmod 0755
      @wrapper_script.close

      mi_run_raw_command '-gdb-set', 'exec-wrapper', mi_quote(@wrapper_script.path), quote: false
    ensure
      @wrapper_script&.close # but not unlink.
    end

    def ruby_interpreter_path
      File.readlink('/proc/self/exe') # Works on Linux
    rescue
      File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name'])
    end
  end
end
