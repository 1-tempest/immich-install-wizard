# Immich Installation Script

This repository contains a script to install and configure Immich, a media server application. The script automates the setup process, including downloading necessary files, configuring environment variables, and starting the Docker containers.

## Prerequisites

- **curl**: Ensure `curl` is installed on your system. The script checks for `curl` and prompts you to install it if not found.

## Installation

1. Navigate to desired Immich installation directory:
    ```
    cd desired/path/to/immich
    ```

2. Download and run the installation script:
    ```
    curl -O https://raw.githubusercontent.com/1-tempest/immich-install-wizard/main/install.sh && sudo ./install.sh
    ```

## Script Overview

The script performs the following steps:

1. **Create Immich Directory**: Sets up the necessary directory structure for Immich.
2. **Download Docker Compose File**: Fetches the latest Docker Compose file from the Immich repository.
3. **Download .env File**: Downloads the environment configuration file.
4. **Generate Random Password**: Generates a random password for the application.
5. **Prompt for Upload Location**: Asks the user to specify the upload location, which can be a local directory or a network mount.
6. **Prompt for External Library**: Prompts the user to add an external library.
7. **Show Mount Paths**: Displays the configured mount paths.
8. **Prompt for Backups**: Asks the user to configure backup settings.
9. **Start Docker Compose**: Starts the Docker containers using the configured settings.

## Usage

- **Upload Location**: You will be prompted to enter the upload location. This can be a local directory or a network mount.
- **External Library**: You can add an external library by providing the path when prompted.
- **Backups**: Configure backup settings as per your requirements.

## Troubleshooting

- Ensure `curl` is installed and accessible in your system's PATH.
- Verify that Docker and Docker Compose are installed and running on your system.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request for any improvements or bug fixes.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
