require "rubygems"
require "sinatra"
require "grit"

configure do
  set :git_dir, "./repos"
  set :description, "View My Rusty Git Repositories"
  set :git_dirs, ["./repos/*.git"]
  set :ignored_files, ['.', '..', 'README.md']
end

# stolen from http://github.com/cschneid/irclogger/blob/master/lib/partials.rb
module Sinatra::Partials
  def partial(template, *args)
    template_array = template.to_s.split('/')
    template = template_array[0..-2].join('/') + "/_#{template_array[-1]}"
    options = args.last.is_a?(Hash) ? args.pop : {}
    options.merge!(:layout => false)
    if collection = options.delete(:collection) then
      collection.inject([]) do |buffer, member|
        buffer << erb(:"#{template}", options.merge(:layout =>
        false, :locals => {template_array[-1].to_sym => member}))
      end.join("\n")
    else
      erb(:"#{template}", options)
    end
  end
end

# Written myself. i know, what the hell?!
module Ginatra

  class Error < StandardError; end
  class CommitsError < Error; end

  # Convenience class for me!
  class RepoList

    def initialize
      @repo_list = Dir.entries(Sinatra::Application.git_dir).
                   delete_if{|e| Sinatra::Application.ignored_files.include? e }.
                   map!{|e| File.expand_path(e, Sinatra::Application.git_dir) }.
                   map!{|e| Repo.new(e) }
    end

    def find(local_param)
      @repo_list.find{|r| r.param == local_param }
    end

    def method_missing(sym, *args, &block)
      @repo_list.send(sym, *args, &block)
    end
  end

  class MultiRepoList < RepoList
    def initialize
      @repo_list = []
      Sinatra::Application.git_dirs.each do |git_dir|
        @repo_list << Dir.glob(git_dir).
                          delete_if{|e| Sinatra::Application.ignored_files.include? e }.
                          map{|e| File.expand_path(e) }
      end
      @repo_list.flatten!
      @repo_list.map!{|e| MultiRepo.new(e) }
    end
  end

  # Convenience class for me!
  class Repo

    attr_reader :name, :param, :description

    def initialize(path)
      @repo = Grit::Repo.new(path)
      @param = File.split(path).last.gsub(/\.git$/, '')
      @name = @param.capitalize
      @description = "Please edit the #{@param}.git/description file for this repository and set the description for it." if /^Unnamed repository;/.match(@repo.description)
      @repo
    end

    def method_missing(sym, *args, &block)
      @repo.send(sym, *args, &block)
    end
  end

  class MultiRepo < Repo

    attr_reader :name, :param, :description

    def self.create!(param)
      @repo_list = MultiRepoList.new
      @repo = @repo_list.find{|r| r.param =~ /^#{Regexp.escape param }$/}
    end
  end

  # Actually useful stuff
  module Helpers
    require "digest/md5"

    def gravatar_url(email)
      "https://secure.gravatar.com/avatar/#{Digest::MD5.hexdigest(email)}?s=40"
    end

    def nicetime(date)
      date.strftime("%b %d, %Y &ndash; %H:%M")
    end

    def actor_box(actor, role, date)
      partial(:actor_box, :locals => {:actor => actor, :role => role, :date => date})
    end

    def actor_boxes(commit)
      if commit.author.name == commit.committer.name
        actor_box(commit.committer, :committer, commit.committed_date)
      else
        actor_box(commit.author, :author, commit.authored_date) + actor_box(commit.committer, :committer, commit.committed_date)
      end
    end

    # The only reason this doesn't work 100% of the time is because grit doesn't :/
    # if i find a fix, it'll go upstream :D
    def file_listing(commit)
      out = commit.diffs.map do |diff|
        if diff.deleted_file
          %(<li class='rm'>#{diff.a_path}</li>)
        else
          cla = diff.new_file ? "add" : "diff"
          %(<li class='#{cla}'>#{diff.a_path}</li>)
        end
      end
      "<ul class='commit-files'>#{out.join}</ul>"
    end

    # Stolen from rails: ActionView::Helpers::TextHelper#simple_format
    #   and simplified to just use <p> tags without any options
    def simple_format(text)
      text.gsub!(/\r\n?/, "\n")                    # \r\n and \r -> \n
      text.gsub!(/\n\n+/, "</p>\n\n<p>")           # 2+ newline  -> paragraph
      text.gsub!(/([^\n]\n)(?=[^\n])/, '\1<br />') # 1 newline   -> br
      text.insert 0, "<p>"
      text << "</p>"
    end
  end

end

helpers do
  include Ginatra::Helpers
  include Sinatra::Partials
end

error Ginatra::CommitsError do
  'No commits were returned for ' + request.uri
end

Sinatra::Application.before do # fixes cucumber compatibility issues
  @repo_list ||= Ginatra::RepoList.new
end

get '/' do
  erb :index
end

get '/:repo' do
  @repo = @repo_list.find(params[:repo])
  @commits = @repo.commits
  raise Ginatra::CommitsError if @commits.empty?
  erb :log
end

get '/:repo/:ref' do
  @repo = @repo_list.find(params[:repo])
  @commits = @repo.commits(params[:ref])
  raise Ginatra::CommitsError if @commits.empty?
  erb :log
end

get '/:repo/commit/:commit' do
  @repo = @repo_list.find(params[:repo])
  @commit = @repo.commit(params[:commit]) # can also be a ref
  erb :commit
end

get '/:repo/tree/:tree' do
  @repo = @repo_list.find(params[:repo])
  @tree = @repo.tree(params[:tree]) # can also be a ref (i think)
  @path = {}
  @path[:tree] = "/#{params[:repo]}/tree/#{params[:tree]}"
  @path[:blob] = "/#{params[:repo]}/blob/#{params[:tree]}"
  erb :tree
end

get '/:repo/tree/:tree/*' do # for when we specify a path
  @repo = @repo_list.find(params[:repo])
  @tree = @repo.tree(params[:tree])/params[:splat].first # can also be a ref (i think)
  if @tree.is_a?(Grit::Blob)
    # we need @tree to be a tree. if it's a blob, send it to the blob page
    # this allows people to put in the remaining part of the path to the file, rather than endless clicks like you need in github
    redirect "/#{params[:repo]}/blob/#{params[:tree]}/#{params[:splat].first}"
  else
    @path = {}
    @path[:tree] = "/#{params[:repo]}/tree/#{params[:tree]}/#{params[:splat].first}"
    @path[:blob] = "/#{params[:repo]}/blob/#{params[:tree]}/#{params[:splat].first}"
    erb :tree
  end
end

get '/:repo/blob/:blob' do
  @repo = @repo_list.find(params[:repo])
  @blob = @repo.blob(params[:blob])
  erb :blob
end

get '/:repo/blob/:tree/*' do
  @repo = @repo_list.find(params[:repo])
  @blob = @repo.tree(params[:tree])/params[:splat].first
  if @blob.is_a?(Grit::Tree)
    # as above, we need @blob to be a blob. if it's a tree, send it to the tree page
    # this allows people to put in the remaining part of the path to the folder, rather than endless clicks like you need in github
    redirect "/#{params[:repo]}/tree/#{params[:tree]}/#{params[:splat].first}"
  else
    erb :blob
  end
end
