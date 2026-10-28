#
# spec file for package bc250-telemetry-log
#
# Copyright (c) 2026 superppl
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License).

Name:           bc250-telemetry-log
Version:        0.1.0
Release:        0
Summary:        CSV log of AMD BC-250 temperatures, power, clocks and fans
License:        MIT
URL:            https://build.opensuse.org/project/show/home:superppl:bc250
Source0:        bc250-telemetry-log.sh
Source1:        bc250-telemetry-log.service
Source2:        bc250-telemetry-log-user.conf
Source3:        LICENSE
# Fake sysfs/procfs and the success/failure tests run in %%check
Source4:        bc250-telemetry-log-mkfake.sh
Source5:        bc250-telemetry-log-tests.sh
BuildRequires:  ShellCheck
BuildRequires:  gawk
BuildRequires:  pkgconfig(systemd)
BuildRequires:  sysuser-tools
Requires:       bash
Requires:       coreutils
%sysusers_requires
%{?systemd_ordering}
BuildArch:      noarch

%description
Appends one CSV row every 10 seconds to /var/log/bc250/telemetry-DATE.csv:
APU, CPU-rail and GFX-rail power, GPU temperatures and clocks from the
governor's copy of gpu_metrics, k10temp Tctl, NVMe temperatures and the
nct6686 temperatures, fan speeds and PWM duty. Reads plain sysfs only and
sends no SMU messages by default. Keeps 45 days and at most 128 MiB.
The service is not enabled on install: systemctl enable --now
bc250-telemetry-log.service.

%prep
%setup -q -c -T
cp %{SOURCE0} %{SOURCE3} %{SOURCE4} %{SOURCE5} .

%build
%sysusers_generate_pre %{SOURCE2} bc250-telemetry bc250-telemetry-log.conf

%install
install -Dm0755 bc250-telemetry-log.sh %{buildroot}%{_bindir}/bc250-telemetry-log
install -Dm0644 %{SOURCE1} %{buildroot}%{_unitdir}/bc250-telemetry-log.service
install -Dm0644 %{SOURCE2} %{buildroot}%{_sysusersdir}/bc250-telemetry-log.conf

%check
shellcheck bc250-telemetry-log.sh bc250-telemetry-log-mkfake.sh bc250-telemetry-log-tests.sh
bash bc250-telemetry-log-tests.sh "$PWD/bc250-telemetry-log.sh" "$PWD/testwork"

%pre -f bc250-telemetry.pre
%service_add_pre bc250-telemetry-log.service

%post
%service_add_post bc250-telemetry-log.service

%preun
%service_del_preun bc250-telemetry-log.service

%postun
%service_del_postun bc250-telemetry-log.service

%files
%license LICENSE
%{_bindir}/bc250-telemetry-log
%{_unitdir}/bc250-telemetry-log.service
%{_sysusersdir}/bc250-telemetry-log.conf

%changelog
