

IMAGE_NAME = "alvistack/ubuntu-22.04"


ENV['VAGRANT_DEFAULT_PROVIDER'] = 'libvirt'

Vagrant.configure("2") do |config|

  ##### DEFINE VMS #####
  config.vm.define "cephadm" do |config|
  config.vm.hostname = "cephadm"
  config.vm.box = IMAGE_NAME
  config.vm.box_check_update = false
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.network "private_network", ip: "192.168.50.10"
  end
  config.vm.provider :libvirt do |v|
    v.qemu_use_session = false
    v.memory = 1024
    v.cpus = 2 
    v.storage :file, :size => '40G', :bus => 'virtio', :type => 'raw', :discard => 'unmap', :detect_zeroes => 'on', :device => 'vdb', :allow_existing => false
    v.storage :file, :size => '40G', :bus => 'virtio', :type => 'raw', :discard => 'unmap', :detect_zeroes => 'on', :device => 'vdc', :allow_existing => false
    v.storage :file, :size => '40G', :bus => 'virtio', :type => 'raw', :discard => 'unmap', :detect_zeroes => 'on', :device => 'vdd', :allow_existing => false
    v.storage :file, :size => '40G', :bus => 'virtio', :type => 'raw', :discard => 'unmap', :detect_zeroes => 'on', :device => 'vde', :allow_existing => false
    v.storage :file, :size => '40G', :bus => 'virtio', :type => 'raw', :discard => 'unmap', :detect_zeroes => 'on', :device => 'vdf', :allow_existing => false
    v.storage :file, :size => '40G', :bus => 'virtio', :type => 'raw', :discard => 'unmap', :detect_zeroes => 'on', :device => 'vdg', :allow_existing => false
    v.storage :file, :size => '40G', :bus => 'virtio', :type => 'raw', :discard => 'unmap', :detect_zeroes => 'on', :device => 'vdh', :allow_existing => false
  end
  config.vm.provision :shell, path: "bootstrap.sh"
end