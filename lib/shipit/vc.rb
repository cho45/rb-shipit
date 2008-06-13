#!/usr/bin/env ruby


require "shipit"
require "tempfile"

module Rake::ShipitTask::VC
	def self.new
		constants.map {|c| const_get(c) }.find {|c|
			c.accept?
		}.new
	end

	class Git
		def self.accept?
			File.exist? ".git"
		end

		def commit(msg)
			temp = Tempfile.open("COMMIT_MESSAGE")
			temp << msg
			temp.close

			system "git", "commit", "-a", "-F", temp.path
		end

		def precommit
			unknown = `git ls-files -z --others --exclude-per-directory=.gitignore --exclude-from=.git/info/exclude`
			if unknown.gsub!(/\0/, "\n")
				raise unknown
			end
		end

		def exists_tagged_version(ver)
			!`git tag -l #{ver}`.empty?
		end


		def tag_version(ver, msg=nil)
			msg = "Tagging version #{ver}." unless msg

			temp = Tempfile.open("COMMIT_MESSAGE")
			temp << msg
			temp.close

			tag = ver

			system "git", "tag", "-a", "-F", temp.path, tag
		end

		def local_diff(file)
			`git diff --no-color HEAD '#{file}'`
		end

		def are_local_diffs(ver)
			`git diff --no-color #{ver}`.match(/\S/)
		end
	end

	class SVN
		def self.accept?
			File.exist? ".svn"
		end

		def commit(msg)
			temp = Tempfile.open("svn-commit")
			temp << msg
			temp.close

			system "svn", "ci", "--file", temp.path
		end

		def precommit
			unknown = []
			changes = false
			`svn st`.split(/\n/).each do |l|
				changes = true
				next unless l =~ /^\?/
				unknown << l
			end

			unless unknown.empty?
				raise unknown.join("\n")
			end

			unless changes
				warn "No locally changed files. skipping commit"
				return
			end
		end

		def exists_tagged_version(ver)
			!!`svn info '#{tag_url(ver)}'`[/Node Kind: directory/]
		end

		def tag_version(ver, msg)
			temp = Tempfile.open("svn-commit")
			temp << msg
			temp.close

			system 'svn', 'copy', '--file', temp.path, trunk_url, tag_url(ver)
		end

		def local_diff(file)
			`svn diff #{file}`
		end

		def are_local_diffs(ver)
			`svn diff`.match(/\S/)
		end

		private
		def tag_url(ver)
			require "uri"
			ENV["LANG"] = "C"
			url = `svn info`[/^URL: (.+)/, 1]
			@url = trunk_url + "."
			unless `svn info '#{(@url + "tags")}'`[/Node Kind: directory/]
				raise "tags directory is not found"
			end
			@url + "tags/#{ver}"
		end

		def trunk_url
			url = `svn info`[/^URL: (.+)/, 1]
			if url =~ /trunk$/
				URI(url)
			else
				raise "Run at trunk! Here is #{url}"
			end
		end
	end
end


