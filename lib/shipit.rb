require "rubygems"
require "rake"
require "rake/tasklib"
require "term/ansicolor"

class Rake::ShipitTask < Rake::TaskLib
	attr_reader :name
	attr_reader :steps

	module Step; end

	include Term::ANSIColor

	def initialize(name=:shipit, &block)
		@name  = name
		@block = block
		define
	end

	def define
		t = Proc.new do |t|
			puts green { "Preparing steps... " }
			steps = []

			def steps.state
				@state ||= {}
			end

			eigenclass = class <<steps; self; end
			plugins = self.class.const_get(:Step)
			plugins.constants.each do |i|
				eigenclass.__send__(:define_method, i) do |*args|
					self << ret = plugins.const_get(i).new(self, *args)
					ret
				end
			end
			@block.call(steps)
			steps.each do |s|
				puts cyan { "Running Step (Prepare): #{s.class.name}" }
				s.prepare if s.respond_to? :prepare
			end
			puts green { "done." }
			unless t.name =~ /:prepare$/
				puts
				puts green { "Steps: #{steps.map{|i| i.class.name.sub(/.+::/, "")}.join(", ")}" }
				puts "Really run? Cancel to press Ctrl+C."
				$stdin.gets
				steps.each do |s|
					puts red { "Running Step: #{s.class.name}" }
					if t.name =~ /:dryrun$/
						begin
							Thread.start do
								$SAFE = 4
								s.run
							end.join
						rescue SecurityError => e
							p e
						end
					else
						s.run
					end
				end
				puts green { "done." }
			end
		end
		desc "Shipit: Automated Release"
		task @name, &t
		namespace @name do
			desc "Shipit: Automated Release (Only run prepare phase)"
			task :prepare, &t
			desc "Shipit: Automated Release (Dry run)"
			task :dryrun, &t
		end
	end
end

class Rake::ShipitTask::Step::Step
	def initialize(step)
	end

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
	def initialize(step, msg=nil)
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
	def initialize(step, file, name="VERSION", vers=VERS)
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
		@vers.replace @new_version
	end

	def run
		puts "Changing version to #{@new_version}"
		@file.open("w") do |f|
			f.print @content[0..@match.begin(1)-1]
			f.print @new_version
			f.print @content[@match.end(1)..-1]
		end
	end
end

class Rake::ShipitTask::Step::Commit
	def initialize(step, msg=nil)
		@msg = msg
	end

	def prepare
		@vers = VERS
		st = `svn st`
		unless st.empty?
			puts "Any changes remain?"
			puts st
			exit
		end
	end

	def run
		system "svn", "ci", "-m", @msg || "Release #{@vers}"
	end
end

class Rake::ShipitTask::Step::Tag
	def initialize(step, format="release-%s")
		@format = format
	end

	def prepare
		require "uri"
		ENV["LANG"] = "C"
		url = `svn info`[/^URL: (.+)/, 1]
		if url =~ /trunk$/
			@url = URI(url) + "."
			unless `svn info '#{(@url + "tags")}'`[/Node Kind: directory/]
				raise "tags directory is not found"
			end
		else
			raise "Run at trunk! Here is #{url}"
		end
		@vers = VERS
	end

	def run
		trunk = @url + "trunk"
		tag   = @url + ("tags/#{@format}" % @vers)
		msg   = "Release %s" % @vers
		command = ["svn", "cp", "-m", msg, trunk, tag].map {|i| i.to_s }
		system(*command)
	end
end


class Rake::ShipitTask::Step::Task
	def initialize(step, *names)
		@names = names
		@tasks = []
	end

	def prepare
		tasks = `rake -T`.scan(/^rake ([^\s]+)/).flatten
		@names.each do |t|
			raise "Unknown task #{t}" unless tasks.include? t.to_s
		end
	end

	def run
		@names.each do |t|
			system("rake", t.to_s)
		end
	end
end

class Rake::ShipitTask::Step::RubyForge
	def initialize(step, group_id=RUBYFORGE_PROJECT)
		@group_id    = group_id
		@description = DESCRIPTION
		@name        = NAME
		@vers        = VERS
	end

	def prepare
		require 'rubyforge'
		@rf = RubyForge.new
		puts "Logging in"
		@rf.login
		@c = @rf.userconfig
		@c["preformatted"] = true
		unless @rf.autoconfig["group_ids"].keys.include?(@group_id)
			raise "Unknown group: #{@group_id}"
		end
		unless @rf.autoconfig["package_ids"].keys.include?(@name)
			@rf.create_package(@group_id, @name)
		end
	end

	def run
		pkg = "pkg/#{@name}-#{@vers}"
		@files = [
			"#{pkg}.tgz",
			"#{pkg}.gem"
		].compact
		puts "Releasing #{@name} #{@vers}"
		@rf.add_release @group_id, @name, @vers, *@files
		@rf.post_news @group_id, "#{@name} #{@vers} released.", "#{@description}"
	end
end

# Skip preceding steps
class Rake::ShipitTask::Step::Skip
	def initialize(step)
		step.clear
	end

	def prepare
	end

	def run
	end
end
