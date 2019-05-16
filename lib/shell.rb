# frozen_string_literal: false
#
#   shell.rb -
#       $Release Version: 0.7 $
#       $Revision: 1.9 $
#       by Keiju ISHITSUKA(keiju@ruby-lang.org)
#
# --
#
#
#

require "e2mmap"

require "forwardable"

require "shell/error"
require "shell/command-processor"
require "shell/process-controller"
require "shell/version"

# Shell implements an idiomatic Ruby interface for common UNIX shell commands.
#
# It provides users the ability to execute commands with filters and pipes,
# like +sh+/+csh+ by using native facilities of Ruby.
#
# == Examples
#
# === Temp file creation
#
# In this example we will create three +tmpFile+'s in three different folders
# under the +/tmp+ directory.
#
#   sh = Shell.cd("/tmp") # Change to the /tmp directory
#   sh.mkdir "shell-test-1" unless sh.exists?("shell-test-1")
#   # make the 'shell-test-1' directory if it doesn't already exist
#   sh.cd("shell-test-1") # Change to the /tmp/shell-test-1 directory
#   for dir in ["dir1", "dir3", "dir5"]
#     if !sh.exists?(dir)
#       sh.mkdir dir # make dir if it doesn't already exist
#       sh.cd(dir) do
#         # change to the `dir` directory
# 	  f = sh.open("tmpFile", "w") # open a new file in write mode
# 	  f.print "TEST\n"            # write to the file
# 	  f.close                     # close the file handler
#       end
#       print sh.pwd                  # output the process working directory
#     end
#   end
#
# === Temp file creation with self
#
# This example is identical to the first, except we're using
# CommandProcessor#transact.
#
# CommandProcessor#transact executes the given block against self, in this case
# +sh+; our Shell object. Within the block we can substitute +sh.cd+ to +cd+,
# because the scope within the block uses +sh+ already.
#
#   sh = Shell.cd("/tmp")
#   sh.transact do
#     mkdir "shell-test-1" unless exists?("shell-test-1")
#     cd("shell-test-1")
#     for dir in ["dir1", "dir3", "dir5"]
#       if !exists?(dir)
# 	  mkdir dir
# 	  cd(dir) do
# 	    f = open("tmpFile", "w")
# 	    f.print "TEST\n"
# 	    f.close
# 	  end
# 	  print pwd
#       end
#     end
#   end
#
# === Pipe /etc/printcap into a file
#
# In this example we will read the operating system file +/etc/printcap+,
# generated by +cupsd+, and then output it to a new file relative to the +pwd+
# of +sh+.
#
#   sh = Shell.new
#   sh.cat("/etc/printcap") | sh.tee("tee1") > "tee2"
#   (sh.cat < "/etc/printcap") | sh.tee("tee11") > "tee12"
#   sh.cat("/etc/printcap") | sh.tee("tee1") >> "tee2"
#   (sh.cat < "/etc/printcap") | sh.tee("tee11") >> "tee12"
#
class Shell

  include Error
  extend Exception2MessageMapper

  # debug: true -> normal debug
  # debug: 1    -> eval definition debug
  # debug: 2    -> detail inspect debug
  @debug = false
  @verbose = true

  @debug_display_process_id = false
  @debug_display_thread_id = true
  @debug_output_mutex = Thread::Mutex.new
  @default_system_path = nil
  @default_record_separator = nil

  class << Shell
    extend Forwardable

    attr_accessor :cascade, :verbose
    attr_reader :debug

    alias debug? debug
    alias verbose? verbose
    @verbose = true

    def debug=(val)
      @debug = val
      @verbose = val if val
    end


    # call-seq:
    #   Shell.cd(path)
    #
    # Creates a new Shell instance with the current working directory
    # set to +path+.
    def cd(path)
      new(path)
    end

    # Returns the directories in the current shell's PATH environment variable
    # as an array of directory names. This sets the system_path for all
    # instances of Shell.
    #
    # Example: If in your current shell, you did:
    #
    #   $ echo $PATH
    #   /usr/bin:/bin:/usr/local/bin
    #
    # Running this method in the above shell would then return:
    #
    #   ["/usr/bin", "/bin", "/usr/local/bin"]
    #
    def default_system_path
      if @default_system_path
        @default_system_path
      else
        ENV["PATH"].split(":")
      end
    end

    # Sets the system_path that new instances of Shell should have as their
    # initial system_path.
    #
    # +path+ should be an array of directory name strings.
    def default_system_path=(path)
      @default_system_path = path
    end

    def default_record_separator
      if @default_record_separator
        @default_record_separator
      else
        $/
      end
    end

    def default_record_separator=(rs)
      @default_record_separator = rs
    end

    # os resource mutex
    mutex_methods = ["unlock", "lock", "locked?", "synchronize", "try_lock"]
    for m in mutex_methods
      def_delegator("@debug_output_mutex", m, "debug_output_"+m.to_s)
    end

  end

  # call-seq:
  #   Shell.new(pwd, umask) -> obj
  #
  # Creates a Shell object which current directory is set to the process
  # current directory, unless otherwise specified by the +pwd+ argument.
  def initialize(pwd = Dir.pwd, umask = nil)
    @cwd = File.expand_path(pwd)
    @dir_stack = []
    @umask = umask

    @system_path = Shell.default_system_path
    @record_separator = Shell.default_record_separator

    @command_processor = CommandProcessor.new(self)
    @process_controller = ProcessController.new(self)

    @verbose = Shell.verbose
    @debug = Shell.debug
  end

  # Returns the command search path in an array
  attr_reader :system_path

  # Sets the system path (the Shell instance's PATH environment variable).
  #
  # +path+ should be an array of directory name strings.
  def system_path=(path)
    @system_path = path
    rehash
  end


  # Returns the umask
  attr_accessor :umask
  attr_accessor :record_separator
  attr_accessor :verbose
  attr_reader :debug

  def debug=(val)
    @debug = val
    @verbose = val if val
  end

  alias verbose? verbose
  alias debug? debug

  attr_reader :command_processor
  attr_reader :process_controller

  def expand_path(path)
    File.expand_path(path, @cwd)
  end

  # Most Shell commands are defined via CommandProcessor

  #
  # Dir related methods
  #
  # Shell#cwd/dir/getwd/pwd
  # Shell#chdir/cd
  # Shell#pushdir/pushd
  # Shell#popdir/popd
  # Shell#mkdir
  # Shell#rmdir

  # Returns the current working directory.
  attr_reader :cwd
  alias dir cwd
  alias getwd cwd
  alias pwd cwd

  attr_reader :dir_stack
  alias dirs dir_stack

  # call-seq:
  #   Shell.chdir(path)
  #
  # Creates a Shell object which current directory is set to +path+.
  #
  # If a block is given, it restores the current directory when the block ends.
  #
  # If called as iterator, it restores the current directory when the
  # block ends.
  def chdir(path = nil, verbose = @verbose)
    check_point

    if block_given?
      notify("chdir(with block) #{path}") if verbose
      cwd_old = @cwd
      begin
        chdir(path, nil)
        yield
      ensure
        chdir(cwd_old, nil)
      end
    else
      notify("chdir #{path}") if verbose
      path = "~" unless path
      @cwd = expand_path(path)
      notify "current dir: #{@cwd}"
      rehash
      Void.new(self)
    end
  end
  alias cd chdir

  # call-seq:
  #   pushdir(path)
  #   pushdir(path) { &block }
  #
  # Pushes the current directory to the directory stack, changing the current
  # directory to +path+.
  #
  # If +path+ is omitted, it exchanges its current directory and the top of its
  # directory stack.
  #
  # If a block is given, it restores the current directory when the block ends.
  def pushdir(path = nil, verbose = @verbose)
    check_point

    if block_given?
      notify("pushdir(with block) #{path}") if verbose
      pushdir(path, nil)
      begin
        yield
      ensure
        popdir
      end
    elsif path
      notify("pushdir #{path}") if verbose
      @dir_stack.push @cwd
      chdir(path, nil)
      notify "dir stack: [#{@dir_stack.join ', '}]"
      self
    else
      notify("pushdir") if verbose
      if pop = @dir_stack.pop
        @dir_stack.push @cwd
        chdir pop
        notify "dir stack: [#{@dir_stack.join ', '}]"
        self
      else
        Shell.Fail DirStackEmpty
      end
    end
    Void.new(self)
  end
  alias pushd pushdir

  # Pops a directory from the directory stack, and sets the current directory
  # to it.
  def popdir
    check_point

    notify("popdir")
    if pop = @dir_stack.pop
      chdir pop
      notify "dir stack: [#{@dir_stack.join ', '}]"
      self
    else
      Shell.Fail DirStackEmpty
    end
    Void.new(self)
  end
  alias popd popdir

  # Returns a list of scheduled jobs.
  def jobs
    @process_controller.jobs
  end

  # call-seq:
  #   kill(signal, job)
  #
  # Sends the given +signal+ to the given +job+
  def kill(sig, command)
    @process_controller.kill_job(sig, command)
  end

  # call-seq:
  #   def_system_command(command, path = command)
  #
  # Convenience method for Shell::CommandProcessor.def_system_command.
  # Defines an instance method which will execute the given shell command.
  # If the executable is not in Shell.default_system_path, you must
  # supply the path to it.
  #
  #    Shell.def_system_command('hostname')
  #    Shell.new.hostname # => localhost
  #
  #    # How to use an executable that's not in the default path
  #
  #    Shell.def_system_command('run_my_program', "~/hello")
  #    Shell.new.run_my_program # prints "Hello from a C program!"
  #
  def Shell.def_system_command(command, path = command)
    CommandProcessor.def_system_command(command, path)
  end

  # Convenience method for Shell::CommandProcessor.undef_system_command
  def Shell.undef_system_command(command)
    CommandProcessor.undef_system_command(command)
  end

  # call-seq:
  #   alias_command(alias, command, *opts, &block)
  #
  # Convenience method for Shell::CommandProcessor.alias_command.
  # Defines an instance method which will execute a command under
  # an alternative name.
  #
  #    Shell.def_system_command('date')
  #    Shell.alias_command('date_in_utc', 'date', '-u')
  #    Shell.new.date_in_utc # => Sat Jan 25 16:59:57 UTC 2014
  #
  def Shell.alias_command(ali, command, *opts, &block)
    CommandProcessor.alias_command(ali, command, *opts, &block)
  end

  # Convenience method for Shell::CommandProcessor.unalias_command
  def Shell.unalias_command(ali)
    CommandProcessor.unalias_command(ali)
  end

  # call-seq:
  #   install_system_commands(pre = "sys_")
  #
  # Convenience method for Shell::CommandProcessor.install_system_commands.
  # Defines instance methods representing all the executable files found in
  # Shell.default_system_path, with the given prefix prepended to their
  # names.
  #
  #    Shell.install_system_commands
  #    Shell.new.sys_echo("hello") # => hello
  #
  def Shell.install_system_commands(pre = "sys_")
    CommandProcessor.install_system_commands(pre)
  end

  #
  def inspect
    if debug.kind_of?(Integer) && debug > 2
      super
    else
      to_s
    end
  end

  def self.notify(*opts)
    Shell::debug_output_synchronize do
      if opts[-1].kind_of?(String)
        yorn = verbose?
      else
        yorn = opts.pop
      end
      return unless yorn

      if @debug_display_thread_id
        if @debug_display_process_id
          prefix = "shell(##{Process.pid}:#{Thread.current.to_s.sub("Thread", "Th")}): "
        else
          prefix = "shell(#{Thread.current.to_s.sub("Thread", "Th")}): "
        end
      else
        prefix = "shell: "
      end
      _head = true
      STDERR.print opts.collect{|mes|
        mes = mes.dup
        yield mes if block_given?
        if _head
          _head = false
          prefix + mes
        else
          " "* prefix.size + mes
        end
      }.join("\n")+"\n"
    end
  end

  CommandProcessor.initialize
  CommandProcessor.run_config
end
