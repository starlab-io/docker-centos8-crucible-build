FROM centos:8.4.2105
MAINTAINER Star Lab <info@starlab.io>
LABEL maintainer="Adam Schwalm <adam.schwalm@starlab.io>"

# Due to CentOS deprecation, change mirrorlist to the vault
# https://github.com/CentOS/sig-cloud-instance-images/issues/190
RUN find /etc/yum.repos.d/ -type f -exec sed -i 's/mirrorlist=/#mirrorlist=/g' {} + && \
    find /etc/yum.repos.d/ -type f -exec sed -i 's/#baseurl=/baseurl=/g' {} + && \
    find /etc/yum.repos.d/ -type f -exec sed -i 's/mirror.centos.org\/$contentdir\/$releasever/vault.centos.org\/8.4.2105/g' {} +

# Install the dnf plugins prior to the general install step below
RUN dnf update -y && dnf install -y \
    # Add the dnf plugins so we can enable PowerTools \
    dnf-plugins-core \
    # Needed for installing cpuid and systemd-networkd inside an installroot \
    epel-release \
    && dnf clean all && \
    rm -rf /var/cache/dnf/* /tmp/* /var/tmp/*

# Enable PowerTools repo so we can install some dev dependencies for building
# xen/qemu/titanium
RUN dnf config-manager --set-enabled powertools

RUN dnf install -y \
    \
    # parallelized gzip \
    pigz \
    \
    # Dependencies for building xen \
    checkpolicy gcc python38 python38-devel iasl ncurses-devel libuuid-devel glib2-devel \
    pixman-devel selinux-policy-devel yajl-devel systemd-devel \
    glibc-devel.i686 glibc-devel flex bison wget \
    \
    # Dependencies for building qemu \
    git libfdt-devel zlib-devel bzip2 ninja-build \
    \
    # Crucible build dependencies \
    rpm-build squashfs-tools openssl-devel rsync python2 clang \
    \
    # Dependencies for starting build as non-root user (see sudo script below) \
    sudo unzip \
    \
    # Dependiences for Transient shared folder support \
    openssh-server \
    \
    # Dependiences for building Titanium libfortifs \
    execstack \
    # For executing test commands in parallel \
    parallel \
    \
    # For Crucible documentation
    graphviz libxslt pandoc python38-pyyaml \
    \
    # For latest grcov/openssl build:
    perl-IPC-Cmd \
    # For building guest images in CI:
    e4fsprogs \
    && dnf clean all && \
    rm -rf /var/cache/dnf/* /tmp/* /var/tmp/*

# Use pigz versions of gzip binaries
RUN  ln -s ../../bin/pigz /usr/local/bin/gzip && ln -s ../../bin/unpigz /usr/local/bin/gunzip

ENV PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/etc/local/cargo/rustup

RUN curl https://sh.rustup.rs -sSf > rustup-install.sh && \
    umask 020 && sh ./rustup-install.sh -y --default-toolchain 1.58.0-x86_64-unknown-linux-gnu && \
    rm rustup-install.sh && \
                            \
    # Install rustfmt / cargo fmt for testing
    rustup component add rustfmt clippy && \
    # Install grcov for coverage
    cargo install grcov --version 0.8.4 --locked && \
    cargo install cargo-deny --version 0.10.3 --locked && \
    # cargo udeps requires nightly to be installed, but doesn't need to be used/default
    rustup install nightly && \
    rustup default 1.58.1-x86_64-unknown-linux-gnu && \
    cargo install cargo-udeps --version 0.1.24 --locked


# Build and install qemu
RUN git clone --depth 1 --branch release-6.0_igb_sriov https://github.com/starlab-io/qemu.git && \
    cd qemu && \
    ./configure --target-list=x86_64-softmmu && \
    make -j4 && make install

# Install python3 dependencies
RUN pip3 install transient==0.24 behave==1.2.6 pyhamcrest==1.10.1 lcov_cobertura==1.6

# Install binary for reformating Gherkin feature files.
RUN wget https://github.com/antham/ghokin/releases/download/v1.6.1/ghokin_linux_amd64 && \
    chmod +x ghokin_linux_amd64 && \
    mv ghokin_linux_amd64 /usr/bin/ghokin

# Set python to be python3
RUN alternatives --set python /usr/bin/python3

# Because lcov is not available in centos8 repos or eple-release, we install from source
RUN git clone https://github.com/linux-test-project/lcov.git && cd lcov && \
    git checkout v1.15 && \
    make dist && \
    dnf install lcov-1.15-1.noarch.rpm -y && \
    make check && \
    cd .. && \
    rm lcov -rf

# The lcov_cobertura package is a python library and binary combined into one file, but is not
# configured as such on pip, and therefore is not executable. We make it executable
# and add to path in order to use it as a binary.
RUN chmod +x /usr/local/lib/python3.8/site-packages/lcov_cobertura.py
ENV PATH="/usr/local/lib/python3.8/site-packages:${PATH}"

# Allow any user to have sudo access within the container
ARG VER=1
ARG ZIP_FILE=add-user-to-sudoers.zip
RUN curl -L -o ${ZIP_FILE} "https://github.com/starlab-io/add-user-to-sudoers/releases/download/${VER}/${ZIP_FILE}" && \
    unzip "${ZIP_FILE}" && \
    rm "${ZIP_FILE}" && \
    mkdir -p /usr/local/bin && \
    mv add_user_to_sudoers /usr/local/bin/ && \
    mv startup_script /usr/local/bin/ && \
    chmod 4755 /usr/local/bin/add_user_to_sudoers && \
    chmod +x /usr/local/bin/startup_script && \
    # Let regular users be able to use sudo
    echo $'auth       sufficient    pam_permit.so\n\
account    sufficient    pam_permit.so\n\
session    sufficient    pam_permit.so\n\
' > /etc/pam.d/sudo

# Install TexLive and required components for Crucible documentation
RUN mkdir /root/tl && wget https://mirror.ctan.org/systems/texlive/tlnet/install-tl-unx.tar.gz -O /dev/stdout |tar -C /root/tl --strip-components=1 -zx  && \
    cd /root/tl && (echo P | ./install-tl -scheme small && \
        sed -i -e 's/instopt_adjustpath 0/instopt_adjustpath 1/' -e 's/instopt_letter 0/instopt_letter 1/'  texlive.profile && \
        ./install-tl -profile texlive.profile) && \
    cd - && \
    rm -rf /root/tl && \
    tlmgr install mdframed zref needspace totalcount seqsplit xpatch draftwatermark && \
    pip3 install yamlordereddictloader texttable

ENV LC_ALL=en_US.utf-8
ENV LANG=en_US.utf-8

ENTRYPOINT ["/usr/local/bin/startup_script"]
CMD ["/bin/bash", "-l"]
