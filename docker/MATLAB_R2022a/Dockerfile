FROM ubuntu:jammy
ARG  DEBIAN_FRONTEND=noninteractive
ENV  TZ=America/Chicago

# Folder name containing MATLAB installer file (must be in root folder of build context)
ARG  MATLAB_INSTALLER_PATH

LABEL org.opencontainers.image.description="MATLAB MRD Image Reconstruction and Analysis Server"
LABEL org.opencontainers.image.url="https://github.com/kspaceKelvin/matlab-ismrmrd-server"
LABEL org.opencontainers.image.authors="Kelvin Chow (kelvin.chow@siemens-healthineers.com)"
EXPOSE 9002

# --------------------------------------------------------------------------------------------------
#      Install Prerequisites
# --------------------------------------------------------------------------------------------------
# Install Docker (MATLAB will use this to build its own Docker containers, as of R2020b)
# Reference: https://www.mathworks.com/help/compiler/package-matlab-standalone-applications-into-docker-images.html
#
# Note that in order to run Docker within a Docker instance, the primary host Docker socket must be
# passed into the container as a shared volume, e.g.:
#   docker run -v /var/run/docker.sock:/var/run/docker.sock ...
#
# If a username-based MATLAB license file is used, then the Docker container is run as a non-root
# user.  If so, the default permissions of /var/run/docker.sock may not allow for non-root users
# to run Docker.  Test this case by starting this Docker container (as a non-root user), then
# attempting to run another nested Docker container:
#   docker run --rm hello-world
#
# If the error "Got permission denied ... /var/run/docker.sock: connect: permission denied"
# appears, exit the Docker container, start another Docker container as root user and run:
#   chmod go+w /var/run/docker.sock
#
# Start another Docker container as non-root user and verify that "docker run" works correctly.
# This "chmod" step may need to be repeated when the host computer is restarted.

RUN apt-get update && \
    apt-get install --no-install-recommends --no-install-suggests --yes apt-transport-https ca-certificates curl software-properties-common && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce

# MATLAB installer requires X11
RUN apt-get update && apt-get install --no-install-recommends --no-install-suggests --yes xorg

# --------------------------------------------------------------------------------------------------
#      Install MATLAB
# --------------------------------------------------------------------------------------------------
# Create and place the following files in the root of the build context:
#  1. installer_input_docker.txt
#    - A modified version of installer_input.txt from the base folder of the MATLAB installer,
#      used as input for unattended installation.  The following fields must be set:
#      - fileInstallationKey (corresponding to the license)
#      - agreeToLicense=yes
#      - licensePath=/tmp/license.lic
#    - At the bottom of the file, select at least the following 3 licenses:
#      - product.MATLAB
#      - product.MATLAB_Compiler
#      - product.Instrument_Control_Toolbox
#  2. license.lic
#  3. The R2022a folder containing the downloaded installer files
COPY installer_input_docker.txt /tmp/
COPY license.lic                /tmp/

# Run the MATLAB installer using the installer_input_docker.txt input.  Installer log messages are
# not displayed in the console, but logged to /tmp/mathworks_root.log.  Check this file if errors
# are encountered.
RUN --mount=type=bind,source=R2022a,target=/tmp/R2022a /tmp/R2022a/install -inputFile /tmp/installer_input_docker.txt

# Some versions of the MATLAB installer do not copy the license file into the installation folder
RUN mkdir -p /usr/local/MATLAB/R2022a/licenses
COPY license.lic /usr/local/MATLAB/R2022a/licenses

# Standalone MATLAB licenses are usually tied to the network card MAC address.  If so, this must be
# set during "docker run", otherwise an automatically generated MAC address will be used, e.g.:
#   docker run --mac-address DE:AD:BE:EF:00:00 ...
#
# The hostname must be set during "docker run":
#   docker run --hostname computername ...

RUN ln -s /usr/local/MATLAB/R2022a/bin/matlab /usr/local/bin/matlab
CMD [ "/usr/local/MATLAB/R2022a/bin/matlab"]

# --------------------------------------------------------------------------------------------------
#      Install MATLAB Compiled Runtime
# --------------------------------------------------------------------------------------------------
# # Option 1: Use this to automatically download the MATLAB Compile Runtime (~3.9 GB)
# RUN /usr/local/MATLAB/R2022a/bin/matlab -r "compiler.runtime.download; quit"

# Option 2: Alternatively, download the MCR from https://ssd.mathworks.com/supportfiles/downloads/R2022a/Release/1/deployment_files/installer/complete/glnxa64/MATLAB_Runtime_R2022a_Update_1_glnxa64.zip
# Place this file in the root of the build context and use the following instead of the above "compiler.runtime.download" call:
# RUN mkdir /root/MCRInstaller9.12
# COPY MATLAB_Runtime_R2022a_Update_1_glnxa64.zip /root/MCRInstaller9.12/
# RUN /usr/local/MATLAB/R2022a/bin/matlab -r "compiler.internal.runtime.utils.setInstallerLocation('/root/MCRInstaller9.12/MATLAB_Runtime_R2022a_Update_1_glnxa64.zip'); quit"

# Note: If a username-based MATLAB license file is used, then replace /root/ in the above commands
# (3 instances) with /home/username/, where username is the licensed username.
# RUN mkdir -p /home/kelvin/MCRInstaller9.12
# COPY MATLAB_Runtime_R2022a_Update_1_glnxa64.zip /home/kelvin/MCRInstaller9.12/
# RUN /usr/local/MATLAB/R2022a/bin/matlab -r "compiler.internal.runtime.utils.setInstallerLocation('/home/kelvin/MCRInstaller9.12/MATLAB_Runtime_R2022a_Update_1_glnxa64.zip'); quit"

# # --------------------------------------------------------------------------------------------------
# #      Copy MATLAB MRD Server code
# # --------------------------------------------------------------------------------------------------
RUN apt-get update && apt-get install -y git
RUN mkdir -p /opt/code
RUN cd /opt/code \
    && git clone https://github.com/kspaceKelvin/matlab-ismrmrd-server.git

# Cleanup files not required after installation
RUN apt-get remove git -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Network MATLAB licenses are usually tied to the username/host.  The username can be set by
# uncommenting the following line with the appropriate username:
RUN useradd -ms /bin/bash kelvin
RUN usermod -aG docker kelvin
RUN echo 'export PATH="/usr/local/MATLAB/R2022a/bin/:$PATH"' > /home/kelvin/.bashrc
RUN chown -R kelvin:kelvin /home/kelvin
USER kelvin

# # --------------------------------------------------------------------------------------------------
# #      How to use this Docker image
# # --------------------------------------------------------------------------------------------------
# # This Docker image can be used to compile and build a Docker image for a MATLAB MRD server.
# # Start Docker with the following options:
# #   docker run                                               \
# #              -it --rm                                      \ # Create an interactive terminal and delete the container when done
# #              --mac-address DE:AD:BE:EF:00:00               \ # Set the MAC address, if required by the MATLAB license
# #              --hostname computername                       \ # Set the hostname, if required by the MATLAB license
# #              -v /var/run/docker.sock:/var/run/docker.sock  \ # Enable Docker within Docker functionality
# #              -v /code:/code                                \ # Share a folder where code can accessed
# #              -p 9002:9002                                  \ # Forward the MRD network port if testing the server
# #               fire-matlab-compiler
# #
# # In the MATLAB Command Prompt, change to the folder containing the server code:
# #   cd /code/matlab-ismrmrd-server
# #
# # Build the standalone application and a Docker image:
# #   res = compiler.build.standaloneApplication('fire_matlab_ismrmrd_server.m')
# #   opts = compiler.package.DockerOptions(res, 'ImageName', 'fire-matlab-server')
# #   compiler.package.docker(res, 'Options', opts)
# #
# # Quit MATLAB and exit the Docker container when complete.  The MCR Docker image should be visible
# # on the host with the name 'fire-matlab-server'.  It can be started with:
# #   docker run --rm -p 9002:9002 fire-matlab-server