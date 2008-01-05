require "rubygems"
require "rake"
require "rake/tasklib"

class Rake::ShipitTask < Rake::TaskLib
	attr_reader :name
	attr_reader :steps

	module Step; end

	def initialize(name=:shipit, &block)
		@name  = name
		@block = block
		define
	end

	def define
		desc "Shipit: Automated Release"
		task @name do
			puts "Preparing steps... "
			steps = []

			eigenclass = class <<steps; self; end
			plugins = self.class.const_get(:Step)
			plugins.constants.each do |i|
				eigenclass.__send__(:define_method, i) do |*args|
					self << ret = plugins.const_get(i).new(*args)
					ret
				end
			end
			@block.call(steps)
			steps.each do |s|
				s.prepare if s.respond_to? :prepare
			end
			puts "done."
			puts "Steps: #{steps.map{|i| i.class.name.sub(/.+::/, "")}.join(", ")}"
			steps.each do |s|
				puts "Running Step: #{s.class.name}"
				s.run
			end
			puts "done."
		end
	end
end

class Rake::ShipitTask::Step::Step
	def new(&block)
		@prepare = block
		self
	end

	def and(&block)
		@run = block
	end

	def prepare
		@prepare.call
	end

	def run
		@run.call
	end
end

class Rake::ShipitTask::Step::Twitter
	def initialize(msg=nil)
		@msg = msg
	end

	def prepare
		require "time"
		require "rubygems"
		gem "twitter4r"
		require "twitter"
		require "pit"
		require "pathname"

		@config = Pit.get("twitter.com", :require => {
				"login"    => "login name",
				"password" => "password"
		})
		@client = Twitter::Client.new(@config)
		raise "Twitter::Client auth failed" unless @client.authenticate?(@config["login"], @config["password"])

		@description = DESCRIPTION
		@name        = NAME
		@vers        = VERS
	end

	def run
		@msg ||= "Released %s %s (%s)" % [@name, @vers, @description]
		@client.status(:post, @msg)
	end
end

class Rake::ShipitTask::Step::ChangeVersion
	def initialize(file, name="VERSION", vers=VERS)
		@file = file
		@name = name
		@vers = vers
	end

	def prepare
		require "pathname"
		@file     = Pathname.new(@file)
		@content  = @file.read
		@match    = @content.match(/#{@name}\s*=\s*['"](\d+\.\d+\.\d+)['"]/)
		@new_version = @match[1].succ
		raise "Can't find version string in #{@file}." if @match.nil?
		puts "Find version string #{@match[1]} and will change to #{@new_version}"
	end

	def run
		puts "Changing version to #{@new_version}"
		@vers.replace @new_version
		@file.open("w") do |f|
			f.print @content[0..@match.begin(1)-1]
			f.print @new_version
			f.print @content[@match.end(1)..-1]
		end
	end
end

class Rake::ShipitTask::Step::Commit
	def initialize(msg=nil)
		@msg = msg
	end

	def prepare
		@vers = VERS
	end

	def run
		system "svn", "ci", "-m", @msg || "Release #{@vers}"
	end
end

class Rake::ShipitTask::Step::Task
	def initialize(*names)
		@names = names
		@tasks = []
	end

	def prepare
		@names.each do |name|
			@tasks << Rake.application[name.to_sym]
			raise "Unknown task: #{name}" if @tasks.last.nil?
		end
	end

	def run
		@tasks.each do |t|
			t.invoke
		end
	end
end

class Rake::ShipitTask::Step::RubyForge
	def initialize(group_id=RUBYFORGE_PROJECT)
		@group_id = group_id
	end

	def prepare
		require 'rubyforge'
		pkg = "pkg/#{NAME}-#{VERS}"
		puts "pkg"

		@rf = RubyForge.new
		puts "Logging in"
		@rf.login
		@c = @rf.userconfig
		@c["preformatted"] = true
		@files = [
			"#{pkg}.tgz",
			"#{pkg}.gem"
		].compact
		unless @rf.autoconfig["group_ids"].keys.include?(@group_id)
			raise "Unknown group: #{@group_id}"
		end
		unless @rf.autoconfig["package_ids"].keys.include?(NAME)
			@rf.create_package(@group_id, NAME)
		end

		@description = DESCRIPTION
		@name        = NAME
		@vers        = VERS
	end

	def run
		puts "Releasing #{@name} #{@vers}"
		@rf.add_release @group_id, @name, @vers, *@files
		@rf.post_news @group_id, "#{@name} #{@vers} released.", "#{@description}"
	end
end

class Rake::ShipitTask::Step::Ask
	def run
		puts "Really run? Cancel to press Ctrl+C."
		$stdin.gets
	end
end

class Rake::ShipitTask::Step::Tag
	def initialize(format="release-%s")
		@format = format
	end

	def prepare
		require "uri"
		ENV["LANG"] = "C"
		url = `svn info`[/^URL: (.+)/, 1]
		if url =~ /trunk$/
			@url = URI(url) + "."
			unless `svn info '#{(@url + "tags")}'`[/Node Kind: directory/]
				raise "tag directory is not found"
			end
		else
			raise "Run at trunk!"
		end
	end

	def run
		trunk = @url + "trunk"
		tag   = @url + ("tags/#{@format}" % VERS)
		msg   = "Release %s" % VERS
		command = ["svn", "cp", "-m", msg, trunk, tag].map {|i| i.to_s }
		system(*command)
	end
end


__END__
require "shipit"

Rake::ShipitTask.new do |s|
	s.Ask
	s.Step.new {
		puts "prepare phase"
	}.and {
		puts "run phase"
	}
	s.Twitter "Test phase"
end

Rake::ShipitTask.new do |s|
	s.Ask
	s.Task :test
	s.ChangeVersion
	s.Commit
	s.Task :clean, :package
	s.RubyForge
	s.Step.new {

	}.and {
	}
	s.Twitter
end

