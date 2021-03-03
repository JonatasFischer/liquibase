#docker build --build-arg MYSQL_DATABASE=test MYSQL_ROOT_PASSWORD=root -t sportradar/example:latest .
FROM debian:stretch-slim AS build

ENV DEBIAN_FRONTEND noninteractive

# Install Git and apt-utils
RUN apt-get update
RUN apt-get install -y apt-utils git && \
    apt-get clean;

# Install OpenJDK-8
RUN mkdir -p /usr/share/man/man1 && \
    apt-get install -y openjdk-8-jre && \
    apt-get clean;

# Fix certificate issues
RUN apt-get install ca-certificates-java && \
    apt-get clean && \
    update-ca-certificates -f;

# Setup JAVA_HOME -- useful for docker commandline
ENV JAVA_HOME /usr/lib/jvm/java-8-openjdk-amd64/
RUN export JAVA_HOME

ENV MYSQL_DATABASE=PRODUCT

#RUN apt-get -yq install mariadb-server-10.1 libmysql-java

#========================================================================================================================
# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN groupadd -r mysql && useradd -r -g mysql mysql

RUN apt-get update && apt-get install -y --no-install-recommends gnupg dirmngr && rm -rf /var/lib/apt/lists/*

# add gosu for easy step-down from root
# https://github.com/tianon/gosu/releases
ENV GOSU_VERSION 1.12
RUN set -eux; \
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends ca-certificates wget; \
	rm -rf /var/lib/apt/lists/*; \
	dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
	wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
	wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
	export GNUPGHOME="$(mktemp -d)"; \
	gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
	gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
	gpgconf --kill all; \
	rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
	apt-mark auto '.*' > /dev/null; \
	[ -z "$savedAptMark" ] || apt-mark manual $savedAptMark > /dev/null; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	chmod +x /usr/local/bin/gosu; \
	gosu --version; \
	gosu nobody true

RUN mkdir /docker-entrypoint-initdb.d

RUN apt-get update && apt-get install -y --no-install-recommends \
# for MYSQL_RANDOM_ROOT_PASSWORD
		pwgen \
# FATAL ERROR: please install the following Perl modules before executing /usr/local/mysql/scripts/mysql_install_db:
# File::Basename
# File::Copy
# Sys::Hostname
# Data::Dumper
		perl \
# install "xz-utils" for .sql.xz docker-entrypoint-initdb.d files
		xz-utils \
	&& rm -rf /var/lib/apt/lists/*

RUN set -ex; \
# gpg: key 5072E1F5: public key "MySQL Release Engineering <mysql-build@oss.oracle.com>" imported
	key='A4A9406876FCBD3C456770C88C718D3B5072E1F5'; \
	export GNUPGHOME="$(mktemp -d)"; \
	gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
	gpg --batch --export "$key" > /etc/apt/trusted.gpg.d/mysql.gpg; \
	gpgconf --kill all; \
	rm -rf "$GNUPGHOME"; \
	apt-key list > /dev/null

ENV MYSQL_MAJOR 5.6
ENV MYSQL_VERSION 5.6.51-1debian9

RUN echo 'deb http://repo.mysql.com/apt/debian/ stretch mysql-5.6' > /etc/apt/sources.list.d/mysql.list

# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter
RUN { \
		echo mysql-community-server mysql-community-server/data-dir select ''; \
		echo mysql-community-server mysql-community-server/root-pass password ''; \
		echo mysql-community-server mysql-community-server/re-root-pass password ''; \
		echo mysql-community-server mysql-community-server/remove-test-db select false; \
	} | debconf-set-selections \
	&& apt-get update \
	&& apt-get install -y \
		mysql-server="${MYSQL_VERSION}" \
# comment out a few problematic configuration values
	&& find /etc/mysql/ -name '*.cnf' -print0 \
		| xargs -0 grep -lZE '^(bind-address|log)' \
		| xargs -rt -0 sed -Ei 's/^(bind-address|log)/#&/' \
# don't reverse lookup hostnames, they are usually another container
	&& echo '[mysqld]\nskip-host-cache\nskip-name-resolve' > /etc/mysql/conf.d/docker.cnf \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm -rf /var/lib/mysql && mkdir -p /var/lib/mysql /var/run/mysqld \
	&& chown -R mysql:mysql /var/lib/mysql /var/run/mysqld \
# ensure that /var/run/mysqld (used for socket and lock files) is writable regardless of the UID our mysqld instance ends up having at runtime
	&& chmod 1777 /var/run/mysqld /var/lib/mysql
#==================================================================================================================
RUN apt-get update && apt-get -yq install libmysql-java

#add liquibase
ADD ./liquibase-4.3.1.tar.gz /opt/liquibase/
#add mysql connector to liquibase lib
RUN cp /usr/share/java/mysql-connector-java.jar  /opt/liquibase/lib/mysql-connector-java.jar


# Make the liquibase project available here, it is needed to fix the problem with the credentials
RUN mkdir /opt/sources/ && \
    cd /opt/sources/ && \
    git clone https://github.com/JonatasFischer/liquibase.git && \
    ls /opt/sources/liquibase/data/PRODUCT/

RUN echo "create database ${MYSQL_DATABASE};" >> init.sql && \
    echo "CREATE USER 'liquibase'@'%' IDENTIFIED BY 'liquibase';" >> init.sql && \
    echo "GRANT ALL PRIVILEGES ON ${MYSQL_DATABASE}.* TO 'liquibase'@'%';" >> init.sql && \
    echo "FLUSH PRIVILEGES;" >> init.sql


ENV LIQUIBASE_ARGS="--url=jdbc:mysql://localhost/${MYSQL_DATABASE} --driver=com.mysql.jdbc.Driver --username=liquibase --password=liquibase --logLevel=info --contexts=testing,pickmatch"

#RUN echo "socket=/var/run/mysqld/mysqld.sock" >> /etc/mysql/mariadb.cnf
RUN /etc/init.d/mysql restart && \
    service mysql status && \
    mysql < init.sql && \
    /opt/liquibase/liquibase --changeLogFile=/opt/sources/liquibase/data/${MYSQL_DATABASE}/db.changelog-setup.xml ${LIQUIBASE_ARGS}  update && \
    mysqldump --single-transaction -Q -K --add-locks ${MYSQL_DATABASE} 2> /dev/null > temp.sql

run cat temp.sql


FROM mysql:5.6
COPY --from=build /var/lib/mysql /var/lib/mysql
RUN ls /var/lib/mysql
EXPOSE 3306
