# frozen_string_literal: true

# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

TASKS = ["test", "rubocop", "build", "yard", "linkinator"].freeze
ISSUE_TASKS = ["bundle", "test", "rubocop", "build", "yard", "linkinator"].freeze

desc "Run CI tasks."

flag :github_event_name, "--github-event-name=EVENT" do |f|
  f.default ""
  f.desc "Name of the github event triggering this job. Optional."
end
flag :github_event_payload, "--github-event-payload=PATH" do |f|
  f.default ""
  f.desc "Path to the github event payload JSON file. Optional."
end
flag :head_commit, "--head=COMMIT" do |f|
  f.desc "Ref or SHA of the head commit when analyzing changes. Defaults to the current commit."
end
flag :base_commit, "--base=COMMIT" do |f|
  f.desc "Ref or SHA of the base commit when analyzing changes. If omitted, uses uncommitted diffs."
end
flag :gems, "--gems=NAMES" do |f|
  f.accept Array
  f.desc "Test the given gems (comma-delimited) instead of analyzing changes."
end
flag :all_gems, "--all-gems[=FILES]" do |f|
  f.desc "Test all gems, or all that include at least one of the given files (comma-delimited)."
end
flag :bundle_retry, "--bundle-retry=RETRIES", accept: Integer, default: 3 do |f|
  f.desc "Number of times to retry bundler network operations (default: 3)"
end

at_least_one_required desc: "Tasks" do
  flag :do_bundle, "--[no-]bundle" do |f|
    f.desc "Normally bundle install is performed prior to any other task. Use --no-bundle to disable this, or " \
           "use --bundle to force a bundle install even if no other tasks are run."
  end
  flag :bundle_update do |f|
    f.desc "Update rather than install gem bundles."
  end
  TASKS.each do |task|
    task_underscore = task.tr "-", "_"
    flag "task_#{task_underscore}", "--[no-]#{task}", desc: "Run the #{task} task"
  end
  flag :all_tasks do |f|
    f.desc "Run all tasks."
  end
end

include :exec
include :terminal, styled: true
include :fileutils

def run
  require "json"
  require "set"

  @cur_dir = Dir.getwd
  Dir.chdir context_directory
  @run_tasks, @bundle_task = determine_tasks
  @errors = []

  determine_dirs.shuffle.each { |dir| run_in_dir dir }
  handle_results
end

def determine_tasks
  run_tasks = TASKS.find_all do |task|
    task_underscore = task.tr "-", "_"
    do_task = get "task_#{task_underscore}"
    do_task.nil? ? all_tasks : do_task
  end
  bundle_task =
    if bundle_update
      logger.info "Will update bundles for tested libraries"
      "update"
    elsif do_bundle == false
      logger.info "Will not install bundles for tested libraries"
      nil
    else
      logger.info "Will install bundles for tested libraries"
      "install"
    end
  logger.info "Running the following tasks: #{run_tasks.inspect}"
  [run_tasks, bundle_task]
end

def determine_dirs
  return gems if gems
  return all_gem_dirs(all_gems || true) if all_gems || github_event_name == "schedule"
  cur_gem_dir || gem_dirs_from_changes
end

def all_gem_dirs which_files
  dirs = Dir.glob("*/*.gemspec").map { |file| File.dirname file }
  if [true, ""].include? which_files
    puts "Running for all gems", :bold
  else
    puts "Running for all gems with the following files: #{which_files}", :bold
    dirs.delete_if do |dir|
      which_files.split(",").all? do |name|
        !File.exist? File.join(dir, name)
      end
    end
  end
  filter_gem_dirs dirs
end

def cur_gem_dir
  root_dir = context_directory
  if @cur_dir != root_dir && @cur_dir.start_with?(root_dir)
    dir = @cur_dir.sub "#{root_dir}/", ""
    dirs = find_changed_directories ["#{dir}/."]
    unless dirs.empty?
      puts "Running in current directory: #{dirs.first}", :bold
      return dirs
    end
  end
  nil
end

def gem_dirs_from_changes
  puts "Evaluating changes.", :bold
  base_ref, head_ref = interpret_github_event
  ensure_checkout head_ref unless head_ref.nil?
  files = find_changed_files base_ref
  if files.empty?
    puts "No files changed.", :bold
  else
    puts "Files changed:", :bold
    files.each { |file| puts "  #{file}" }
  end

  dirs = find_changed_directories files
  if dirs.empty?
    puts "No gem directories changed.", :bold
  else
    puts "Gem directories changed:", :bold
    dirs.each { |dir| puts "  #{dir}" }
  end
  dirs
end

def interpret_github_event
  payload = JSON.parse File.read github_event_payload unless github_event_payload.empty?
  base_ref, head_ref =
    case github_event_name
    when "pull_request"
      logger.info "Getting commits from pull_request event"
      [payload["pull_request"]["base"]["ref"], nil]
    when "push"
      logger.info "Getting commits from push event"
      [payload["before"], nil]
    when "workflow_dispatch"
      logger.info "Getting inputs from workflow_dispatch event"
      [payload["inputs"]["base"], payload["inputs"]["head"]]
    else
      logger.info "Using local commits"
      [base_commit, head_commit]
    end
  base_ref = nil if base_ref&.empty?
  head_ref = nil if head_ref&.empty?
  [base_ref, head_ref]
end

def ensure_checkout head_ref
  logger.info "Checking for head ref: #{head_ref}"
  head_sha = ensure_fetched head_ref
  current_sha = capture(["git", "rev-parse", "HEAD"], e: true).strip
  if head_sha == current_sha
    logger.info "Already at head SHA: #{head_sha}"
  else
    logger.info "Checking out head SHA: #{head_sha}"
    exec ["git", "checkout", head_sha], e: true
  end
end

def find_changed_files base_ref
  if base_ref.nil?
    logger.info "No base ref. Using local diff."
    capture(["git", "status", "--porcelain"]).split("\n").map { |line| line.split.last }
  else
    logger.info "Diffing from base ref: #{base_ref}"
    base_sha = ensure_fetched base_ref
    capture(["git", "diff", "--name-only", base_sha], e: true).split("\n").map(&:strip)
  end
end

def ensure_fetched ref
  result = exec ["git", "show", "--no-patch", "--format=%H", ref], out: :capture, err: :capture
  if result.success?
    result.captured_out.strip
  elsif ref == "HEAD^"
    # Common special case
    current_sha = capture(["git", "rev-parse", "HEAD"], e: true).strip
    exec ["git", "fetch", "--depth=2", "origin", current_sha], e: true
    capture(["git", "rev-parse", "HEAD^"], e: true).strip
  else
    logger.info "Fetching ref: #{ref}"
    exec ["git", "fetch", "--depth=1", "origin", "#{ref}:refs/temp/#{ref}"], e: true
    capture(["git", "show", "--no-patch", "--format=%H", "refs/temp/#{ref}"], e: true).strip
  end
end

def find_changed_directories files
  dirs = Set.new
  files.each do |file|
    next unless file =~ %r{^([^/]+)/.+$}
    dir = Regexp.last_match[1]
    dirs << dir
    next unless dir =~ %r{^(.+)-v\d[^-]*$}
    wrapper_dir = Regexp.last_match[1]
    next unless Dir.exist? wrapper_dir
    dirs << wrapper_dir
  end
  filter_gem_dirs dirs.to_a
end

def filter_gem_dirs dirs
  dirs.find_all do |dir|
    if ["Gemfile", "#{dir}.gemspec"].all? { |file| File.file? File.join(dir, file) }
      result = capture_ruby [], in: :controller do |controller|
        controller.in.puts "spec = Gem::Specification.load '#{dir}/#{dir}.gemspec'"
        controller.in.puts "puts spec.required_ruby_version.satisfied_by? Gem::Version.new(#{RUBY_VERSION.inspect})"
      end
      result.strip == "true"
    else
      false
    end
  end.sort
end

def run_toplevel
  if @bundle_task
    puts
    puts "toplevel: bundle ...", :bold, :cyan
    result = exec ["bundle", @bundle_task, "--retry=#{bundle_retry}"]
    unless result.success?
      @errors << [dir, "bundle"]
      return
    end
  end
  if task_rubocop_toplevel
    puts
    puts "toplevel: rubocop ...", :bold, :cyan
    result = exec ["bundle", "exec", "rubocop", "-c", ".rubocop_root.yml"]
    @errors << ["toplevel", "rubocop"] unless result.success?
  end
end

def run_in_dir dir
  Dir.chdir dir do
    if @bundle_task
      puts
      puts "#{dir}: bundle ...", :bold, :cyan
      result = exec ["bundle", @bundle_task, "--retry=#{bundle_retry}"]
      unless result.success?
        @errors << [dir, "bundle"]
        next
      end
    end
    @run_tasks.each do |task|
      puts
      puts "#{dir}: #{task} ...", :bold, :cyan
      result = exec_separate_tool [task] + verbosity_flags, env: @auth_env
      @errors << [dir, task] unless result.success?
    end
  end
end

def handle_results
  puts
  if @errors.empty?
    puts "CI passed", :bold, :green
  else
    puts "FAILURES:", :bold, :red
    @errors.each { |dir, task| puts "#{dir}: #{task}", :yellow }
    exit 1
  end
end
