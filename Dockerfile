ARG PHP_VERSION="8.3"

## base ##########################################################################
FROM wordpress:php${PHP_VERSION}-apache AS base

# Install make 
RUN apt update && \
    apt install -y make less bash-completion
RUN echo "[ -f /etc/bash_completion ] && . /etc/bash_completion" >> /var/www/.bashrc

# Install nodejs / npm
RUN apt install -y nodejs npm 

# Install wp-cli
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
    chmod +x wp-cli.phar && \
    mv wp-cli.phar /usr/local/bin/wp

RUN curl -O https://raw.githubusercontent.com/wp-cli/wp-cli/v2.11.0/utils/wp-completion.bash && \
    chmod +x wp-completion.bash && \
    mv wp-completion.bash /usr/local/include/ && \
    echo "source /usr/local/include/wp-completion.bash" >> /etc/bash.bashrc;

# Custom image for the DEV
RUN cp /etc/bash.bashrc /var/www/.bashrc && \
    echo "alias ll='ls -al --color'" >> /var/www/.bashrc

# Change ID de www-data
ARG USER_UID
ARG USER_GID

RUN usermod -u ${USER_UID} www-data && \
    groupmod -g ${USER_GID} www-data

RUN mkdir /var/www/.wp-cli && chown -R www-data:www-data /var/www/.wp-cli
RUN mkdir /var/www/.npm && chown -R www-data:www-data /var/www/.npm

USER ${USER_UID}:${USER_GID}
