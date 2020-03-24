class Orc
  attr_reader :io

  def initialize backing_store
    @store = backing_store
    cmd = ['orc', '-S', @store, 'batch-edit']
    @io = IO.popen({}, cmd, 'w', :err => :out)
  end

  def new_register register_name
    cmd = ['orc', '-S', @store, 'init', register_name]
    @task = IO.popen({}, cmd, 'r')
    Process::waitpid @task.pid
  end

  def ensure_entry register, region, key, *items
    @io.write "(ensure-entry \"#{register}\" \"#{region}\" \"#{key}\" #{items.map(&:inspect).join(' ')})\n"
  end

  def ensure_items register, region, key, *items
    @io.write "(ensure-items \"#{register}\" \"#{region}\" \"#{key}\" #{items.map(&:inspect).join(' ')})\n"
  end

  def delete_untouched register, region
    @io.write "(delete-untouched \"#{register}\" \"#{region}\")\n"
  end

  def to_rsf name, file
    cmd = ['orc', '-S', @store, 'dump', name]
    @task = IO.popen({}, cmd, 'w', :out => file)
    Process::waitpid @task.pid
  end

  def close
    @io.close
  end
end
