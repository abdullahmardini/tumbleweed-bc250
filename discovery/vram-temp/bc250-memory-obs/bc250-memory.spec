#
# spec file for package bc250-memory
#
# Copyright (c) 2026 superppl
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License).

%global commit de4740c9b60b93c36f3ff6c85789e4aea3cefe31
%global shortcommit de4740c

Name:           bc250-memory
Version:        0~git20261002.de4740c
Release:        0
Summary:        GDDR6 VRAM temperature hwmon driver for the AMD BC-250
# Driver code: GPL-2.0-or-later. Embedded SMU payload (derived from
# pan-Rijovich/bc250-memory-temperature): MIT. Module is Dual MIT/GPL.
License:        GPL-2.0-or-later AND MIT
URL:            https://github.com/Hexxeh/bc250-memory-dkms
Source0:        %{url}/archive/%{commit}.tar.gz#/bc250-memory-dkms-%{commit}.tar.gz
Source1:        %{name}.conf
Source2:        %{name}-files
Source3:        %{name}-preamble
BuildRequires:  %kernel_module_package_buildreqs
BuildRequires:  kernel-default-devel
ExclusiveArch:  x86_64
# No -b: the driver is not needed before the root file system
%kernel_module_package -p %{name}-preamble -f %{name}-files

%description
Hexxeh's out-of-tree bc250_memory driver. It patches the BC-250 SMU at
runtime (auto_patch, default on upstream) and then reads each GDDR6 chip's
JEDEC MR3 temperature over SMU Queue 3, exposing VRAM Hotspot/Average and
per-chip temperatures through hwmon.

WARNING: the driver drives the shared SMU index/data pair at 0xB8/0xBC on
00:00.0 with no advisory lock, so it can collide with the GPU governor
(cyan-skillfish-governor-smu, Queue 3) and wedge the SMU. On stock P3.00
firmware (no SMU-unlock BIOS mod) auto_patch cannot open the SMU debug gate
and the probe bails. Nothing autoloads this module; the shipped modprobe.d
sets auto_patch=0 so a plain load is inert.

%prep
%setup -q -n bc250-memory-dkms-%{commit}

%build
for flavor in %{flavors_to_build}; do
	rm -rf obj/$flavor
	mkdir -p obj/$flavor
	cp Makefile bc250_memory.c bc250_smu.c bc250_smu.h bc250_smu_patch.c obj/$flavor/
	%make_build -C %{_prefix}/src/linux-obj/%{_target_cpu}/$flavor \
		M=$PWD/obj/$flavor modules
	ko=obj/$flavor/bc250_memory.ko
	krel=$(cat %{_prefix}/src/linux-obj/%{_target_cpu}/$flavor/include/config/kernel.release)
	/sbin/modinfo -F parm $ko | grep '^auto_patch:'
	/sbin/modinfo -F license $ko | grep '^Dual MIT/GPL$'
	/sbin/modinfo -F vermagic $ko | grep "^$krel "
done

%install
export INSTALL_MOD_PATH=%{buildroot}
export INSTALL_MOD_DIR=updates
for flavor in %{flavors_to_build}; do
	make -C %{_prefix}/src/linux-obj/%{_target_cpu}/$flavor \
		M=$PWD/obj/$flavor modules_install
done
install -Dm0644 %{SOURCE1} %{buildroot}%{_modprobedir}/50-bc250-memory.conf

%changelog
