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

RUN apt-get -yq install mariadb-server-10.1 libmysql-java

#add liquibase
ADD ./liquibase-4.3.1.tar.gz /opt/liquibase/
#add mysql connector to liquibase lib
RUN cp /usr/share/java/mysql-connector-java.jar  /opt/liquibase/lib/mysql-connector-java.jar


RUN echo "drop database IF EXISTS ${MYSQL_DATABASE};" >> init.sql && \
    echo "create database ${MYSQL_DATABASE};" >> init.sql && \
    echo "drop user if EXISTS 'liquibase'@'localhost';" >> init.sql && \
    echo "CREATE USER 'liquibase'@'localhost' IDENTIFIED BY 'liquibase';" >> init.sql && \
    echo "GRANT ALL PRIVILEGES ON ${MYSQL_DATABASE}.* TO 'liquibase'@'localhost';" >> init.sql && \
    echo "FLUSH PRIVILEGES;" >> init.sql

# Make the liquibase project available here, it is needed to fix the problem with the credentials
RUN mkdir /opt/sources/ && \
    cd /opt/sources/ && \
    git clone https://github.com/JonatasFischer/liquibase.git && \
    ls /opt/sources/liquibase/data/PRODUCT/

ENV LIQUIBASE_ARGS="--url=jdbc:mysql://localhost/${MYSQL_DATABASE} --driver=com.mysql.jdbc.Driver --username=liquibase --password=liquibase --logLevel=info --contexts=testing,pickmatch"

#RUN echo "socket=/var/run/mysqld/mysqld.sock" >> /etc/mysql/mariadb.cnf
RUN /etc/init.d/mysql restart && \
    service mysql status && \
    mysql < init.sql && \
    mysql < init.sql && \
    /opt/liquibase/liquibase --changeLogFile=/opt/sources/liquibase/data/${MYSQL_DATABASE}/db.changelog-setup.xml ${LIQUIBASE_ARGS}  update;


FROM mysql:5.6
COPY --from=build /var/lib/mysql /var/lib/mysql
RUN ls /var/lib/mysql
EXPOSE 3306
