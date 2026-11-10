# The Kali container the tests workflow runs tests/container in: Kali rolling with bats, equivs
# and dpkg-dev to build dummy kernel packages, linux-base for linux-update-symlinks,
# linux-version and linux-run-hooks, util-linux and mount for the mounts and loop devices,
# e2fsprogs for the ext4 image the hook tests mount on /boot, mawk, gawk and grub-common. The
# base image is pinned by digest; Dependabot proposes updates. Run it with --privileged for the
# mounts.
FROM kalilinux/kali-rolling:latest@sha256:7997e0581c4f5c185cfe6773d5cae8fcc7c6b79798726ccaabf843af4bcd2013

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        bats dpkg-dev e2fsprogs equivs gawk grub-common linux-base mawk mount util-linux \
    && rm -rf /var/lib/apt/lists/*

# The container tests install packages and mount over /boot, so they run only where this is set.
ENV KU_CONTAINER=1
WORKDIR /src
CMD ["bats", "--tap", "tests/container"]
