# Perforce source control implementation for CruiseControl.rb
# Written by Christopher Bailey, mailto:chris@codeintensity.com
module SourceControl

class Perforce
  include CommandLine

  class Revision < Subversion::Revision
  end

  attr_accessor :port, :client_spec, :username, :password, :path

  MAX_CHANGELISTS_TO_FETCH = 25

  def initialize(options = {})
    @port, @clientspec, @username, @password, @depot_path, @interactive =
          options.delete(:port), options.delete(:clientspec),
                    options.delete(:user), options.delete(:password),
                    options.delete(:path), options.delete(:interactive)
    raise "don't know how to handle '#{options.keys.first}'" if options.length > 0
    @clientspec or raise 'P4 Clientspec not specified'
    @port or raise 'P4 Port not specified'
    @username or raise 'P4 username not specified'
    @password or raise 'P4 password not specified'
    @depot_path or raise 'P4 depot path not specified'
  end

  def latest_revision
    # Get the latest changelist for this project
    change = p4(:changes, "-m 1 #{@depot_path}").first
    desc = get_changedesc(change['change'])
    changesets = get_changeset(desc)
    Revision.new(desc['change'].to_i, desc['user'], Time.at(desc['time'].to_i), desc['desc'], changesets)
  end

  def creates_ordered_build_labels?() true end

  def last_locally_known_revision
    change = p4(:changes, "-m 1 @#{@clientspec}").first
    desc = get_changedesc(change['change'])
    changesets = get_changeset(desc)
    Revision.new(desc['change'].to_i, desc['user'], Time.at(desc['time'].to_i), desc['desc'], changesets)
  end

  def up_to_date?(reasons = [], revision_number = last_locally_known_revision.number)
    result = true
    
    latest_revision = self.latest_revision()
    if latest_revision > Revision.new(revision_number)
      reasons << "New revision #{latest_revision.number} detected"
      reasons << revisions_since(revision_number)
      result = false
    end
    
    return result
  end

  SYNC_PATTERN = /^(\/\/.+#\d+) - (\w+) .+$/
  def update(revision = nil)
    sync_output = p4(:sync, revision.nil? ? "" : "#{@depot_path}@#{revision_number(revision)}")
    synced_files = Array.new
   
    sync_output.each do |line|
      match = SYNC_PATTERN.match(line['data'])
      if match
        file, operation = match[1..2]
        synced_files << ChangesetEntry.new(operation, file)
      end
    end.compact
    synced_files
  end
  
  def revisions_since(revision_number)
    # This should get all changelists since the last one we used, but when using
    # the -R flag with P4 it only seems to get the latest one.
    changelists = p4(:changes, "-m #{MAX_CHANGELISTS_TO_FETCH} #{@depot_path}@#{revision_number},#head")
   
    changes = Array.new
    changelists.each do |cl|
      desc = get_changedesc(cl['change'])
      changeset = get_changeset(desc)     
      changes << Revision.new(desc['change'].to_i, desc['user'], Time.at(desc['time'].to_i), desc['desc'], changeset)
    end
    changes.delete_if { |r| r.number == revision_number }
    changes
  end
 
  def checkout(revision = nil, stdout = $stdout)
    # No need for target_directory with Perforce, since this is controlled by
    # the clientspec.
    options = ""
    options << "#{@depot_path}##{revision_number(revision)}" unless revision.nil?
    # need to read from command output, because otherwise tests break
    p4(:sync, options).each {|line| stdout.puts line.to_s }
  end

  private
 
  # Execute a P4 command, and return an array of the resulting output lines
  # The array will contain a hash for each line out output
  def p4(operation, options = nil)
    p4cmd = "p4 -R -p #{@port} -c #{@clientspec} -u #{@username} -P #{@password} "
    p4cmd << "#{operation.to_s}"
    p4cmd << " " << options if options
    p4_output = Array.new
    File.open('/tmp/perforce.log','a') do |logfile|
      logfile.puts(p4cmd)
      IO.popen(p4cmd, "rb") do |file|
        while not file.eof
          p4_output << Marshal.load(file)
        end
      end
      logfile.puts(p4_output)
    end
    p4_output
  end

  # Execute a P4 describe and return a easy to use hash
  def get_changedesc(change)
    output = p4(:describe, "-s #{change}")
    files =[]
    desc = {}
    output.first.each do |key,value|
      if ( key =~ /(.*?)(\d+$)/ )
        idx = Integer($2)
        filekey = $1
        files[idx] = {} if (files[idx] == nil)
        files[idx][filekey] = value
      else
        desc[key] = value
      end
    end
    desc["files"] = files
    desc
  end

  def get_changeset(desc)
    entries = desc["files"].collect do |file|
      ChangesetEntry.new(file["action"] , file["depotFile"])
    end
    entries.sort_by{|entry| entry.file }
  end

  def revision_number(revision)
    revision.respond_to?(:number) ? revision.number : revision.to_i
  end
 
  Info = Struct.new :revision, :last_changed_revision, :last_changed_author
end

end