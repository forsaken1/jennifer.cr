require "db"

module Jennifer
  module Adapter
    abstract class Base
      @db : DB::Database
      @transaction : DB::Transaction? = nil
      @locks = {} of UInt64 => DB::Transaction

      getter db

      def initialize
        @db = DB.open(Base.connection_string(:db))
      end

      def self.build
        a = new
        a.prepare
        a
      end

      def prepare
      end

      def with_connection(&block)
        if @locks.has_key?(Fiber.current.object_id)
          yield @locks[Fiber.current.object_id].connection
        else
          conn = @db.checkout
          res = yield conn
          conn.release
          res
        end
      end

      def with_manual_connection(&block)
        conn = @db.checkout
        res = yield conn
        conn.release
        res
      end

      def with_transactionable(&block)
        if @locks.has_key?(Fiber.current.object_id)
          yield @locks[Fiber.current.object_id]
        else
          conn = @db.checkout
          res = yield conn
          conn.release
          res
        end
      end

      def lock_connection(transaction : DB::Transaction)
        @locks[Fiber.current.object_id] = transaction
      end

      def lock_connection(transaction : Nil)
        @locks.delete(Fiber.current.object_id)
      end

      def current_transaction
        @locks[Fiber.current.object_id]?
      end

      def exec(_query, args = [] of DB::Any)
        Config.logger.debug { regular_query_message(_query, args) }
        with_connection { |conn| conn.exec(_query, args) }
      rescue e : Exception
        raise BadQuery.new(e.message, regular_query_message(_query, args))
      end

      def query(_query, args = [] of DB::Any)
        Config.logger.debug { regular_query_message(_query, args) }
        with_connection { |conn| conn.query(_query, args) { |rs| yield rs } }
      rescue e : Exception
        raise BadQuery.new(e.message, regular_query_message(_query, args))
      end

      def scalar(_query, args = [] of DB::Any)
        Config.logger.debug { regular_query_message(_query, args) }
        with_connection { |conn| conn.scalar(_query, args) }
      rescue e : Exception
        raise BadQuery.new(e.message, regular_query_message(_query, args))
      end

      def transaction(&block)
        previous_transaction = current_transaction
        with_transactionable do |conn|
          conn.transaction do |tx|
            lock_connection(tx)
            begin
              Config.logger.debug("TRANSACTION START")
              yield(tx)
              Config.logger.debug("TRANSACTION COMMIT")
            rescue e
              Config.logger.debug("TRANSACTION ROLLBACK")
              raise e
            ensure
              lock_connection(previous_transaction)
            end
          end
        end
      end

      def begin_transaction
        raise ::Jennifer::BaseException.new("Couldn't manually begin non top level transaction") if current_transaction
        Config.logger.debug("TRANSACTION START")
        lock_connection(@db.checkout.begin_transaction)
      end

      def rollback_transaction
        t = current_transaction
        raise ::Jennifer::BaseException.new("No transaction to rollback") unless t
        t = t.not_nil!
        t.rollback
        Config.logger.debug("TRANSACTION ROLLBACK")
        t.connection.release
        lock_connection(nil)
      end

      def truncate(klass : Class)
        truncate(klass.table_name)
      end

      def truncate(table_name : String)
        exec "TRUNCATE #{table_name}"
      end

      def delete(query : QueryBuilder::Query)
        body = String.build do |s|
          query.from_clause(s)
          s << query.body_section
        end
        args = query.select_args
        exec "DELETE #{parse_query(body, args)}", args
      end

      def exists?(query)
        args = query.select_args
        body = String.build do |s|
          s << "SELECT EXISTS(SELECT 1 "
          query.from_clause(s)
          s << parse_query(query.body_section, args) << ")"
        end
        scalar(body, args) == 1
      end

      def count(query)
        body = String.build do |s|
          query.from_clause(s)
          s << query.body_section
        end
        args = query.select_args
        scalar("SELECT COUNT(*) #{parse_query(body, args)}", args).as(Int64).to_i
      end

      def self.db_connection
        DB.open(connection_string) do |db|
          yield(db)
        end
      rescue e
        puts e
        raise e
      end

      def self.join_table_name(table1, table2)
        [table1.to_s, table2.to_s].sort.join("_")
      end

      def self.connection_string(*options)
        auth_part = Config.user
        auth_part += ":#{Config.password}" if Config.password && !Config.password.empty?
        str = "#{Config.adapter}://#{auth_part}@#{Config.host}"
        str += "/" + Config.db if options.includes?(:db)
        str += "?"
        str += [
          {% for arg in [:max_pool_size, :initial_pool_size, :max_idle_pool_size, :retry_attempts, :checkout_timeout, :retry_delay] %}
            "{{arg.id}}=#{Config.{{arg.id}}}"
          {% end %},
        ].join(",")
        str
      end

      def self.extract_arguments(hash)
        args = [] of DBAny
        fields = [] of String
        hash.each do |key, value|
          fields << key.to_s
          args << value
        end
        {args: args, fields: fields}
      end

      def result_to_array(rs)
        a = [] of DBAny
        rs.columns.each do |col|
          temp = rs.read(DBAny)
          if temp.is_a?(Int8)
            temp = (temp == 1i8).as(Bool)
          end
          a << temp
        end
        a
      end

      def result_to_array_by_names(rs, names)
        buf = {} of String => DBAny
        names.each { |n| buf[n] = nil }
        count = names.size
        rs.column_count.times do |col|
          col_name = rs.column_name(col)
          if buf.has_key?(col_name)
            buf[col_name] = rs.read.as(DBAny)
            if buf[col_name].is_a?(Int8)
              buf[col_name] = (buf[col_name] == 1i8).as(Bool)
            end
            count -= 1
          else
            rs.read
          end
          break if count == 0
        end
        buf.values
      end

      # converts single ResultSet to hash
      def result_to_hash(rs)
        h = {} of String => DBAny
        rs.column_count.times do |col|
          col_name = rs.column_name(col)
          h[col_name] = rs.read.as(DBAny)
          if h[col_name].is_a?(Int8)
            h[col_name] = (h[col_name] == 1i8).as(Bool)
          end
        end
        h
      end

      # converts single ResultSet which contains several tables
      def table_row_hash(rs)
        h = {} of String => Hash(String, DBAny)
        rs.columns.each do |col|
          h[col.table] ||= {} of String => DBAny
          h[col.table][col.name] = rs.read
          if h[col.table][col.name].is_a?(Int8)
            h[col.table][col.name] = h[col.table][col.name] == 1i8
          end
        end
        h
      end

      def parse_query(query, args)
        arr = [] of String
        args.each do
          arr << "?"
        end
        query % arr
      end

      def parse_query(query)
        query
      end

      def self.arg_replacement(arr)
        escape_string(arr.size)
      end

      def self.escape_string(size = 1)
        case size
        when 1
          "%s"
        when 2
          "%s, %s"
        when 3
          "%s, %s, %s"
        else
          size.times.map { "%s" }.join(", ")
        end
      end

      def self.drop_database
        db_connection do |db|
          db.exec "DROP DATABASE #{Config.db}"
        end
      end

      def self.create_database
        db_connection do |db|
          puts db.exec "CREATE DATABASE #{Config.db}"
        end
      end

      def self.generate_schema
      end

      def self.load_schema
      end

      # filter out value; should be refactored
      def self.t(field)
        case field
        when Nil
          "NULL"
        when String
          "'" + field + "'"
        else
          field
        end
      end

      # migration ========================

      def ready_to_migrate!
        return if table_exists?(Migration::Base::TABLE_NAME)
        tb = Migration::TableBuilder::CreateTable.new(Migration::Base::TABLE_NAME)
        tb.integer(:id, {:primary => true, :auto_increment => true})
          .string(:version, {:size => 17})
        create_table(tb)
      end

      def rename_table(old_name, new_name)
        exec "ALTER TABLE #{old_name.to_s} RENAME #{new_name.to_s}"
      end

      def add_index(table, name, options)
        query = String.build do |s|
          s << "CREATE "
          if options[:type]?
            s <<
              case options[:type]
              when :unique, :uniq
                "UNIQUE "
              when :fulltext
                "FULLTEXT "
              when :spatial
                "SPATIAL "
              when nil
                " "
              else
                raise ArgumentError.new("Unknown index type: #{options[:type]}")
              end
          end
          s << "INDEX " << name << " ON " << table << "("
          fields = options.as(Hash)[:_fields].as(Array)
          fields.each_with_index do |f, i|
            s << "," if i != 0
            s << f
            s << "(" << options[:length].as(Hash)[f] << ")" if options[:length]? && options[:length].as(Hash)[f]?
            s << " " << options[:order].as(Hash)[f].to_s.upcase if options[:order]? && options[:order].as(Hash)[f]?
          end
          s << ")"
        end
        exec query
      end

      def drop_index(table, name)
        exec "DROP INDEX #{name} ON #{table}"
      end

      def drop_column(table, name)
        exec "ALTER TABLE #{table} DROP COLUMN #{name}"
      end

      def add_column(table, name, opts)
        query = String.build do |s|
          s << "ALTER TABLE " << table << " ADD COLUMN "
          column_definition(name, opts, s)
        end

        exec query
      end

      def change_column(table, old_name, new_name, opts)
        query = String.build do |s|
          s << "ALTER TABLE " << table << " CHANGE COLUMN " << old_name << " "
          column_definition(new_name, opts, s)
        end

        exec query
      end

      def drop_table(builder : Migration::TableBuilder::DropTable)
        exec "DROP TABLE #{builder.name}"
      end

      def create_table(builder : Migration::TableBuilder::CreateTable)
        buffer = String.build do |s|
          s << "CREATE TABLE " << builder.name << " ("
          builder.fields.each_with_index do |(name, options), i|
            s << ", " if i != 0
            column_definition(name, options, s)
          end
        end
        exec buffer + ")"
      end

      def create_enum(name, options)
        raise BaseException.new("Current adapter not support this method.")
      end

      def drop_enum(name, options)
        raise BaseException.new("Current adapter not support this method.")
      end

      def change_enum(name, options)
        raise BaseException.new("Current adapter not support this method.")
      end

      abstract def update(obj)
      abstract def update(q, h)
      abstract def insert(obj)
      abstract def distinct(q, c, t)
      abstract def table_exists?(table)
      abstract def index_exists?(table, name)
      abstract def column_exists?(table, name)
      abstract def translate_type(name)
      abstract def default_type_size(name)

      private def column_definition(name, options, io)
        type = options[:serial]? ? "serial" : (options[:sql_type]? || translate_type(options[:type].as(Symbol)))
        size = options[:size]? || default_type_size(options[:type])
        io << name << " " << type
        io << "(#{size})" if size
        if options[:type] == :enum
          io << " ("
          options[:values].as(Array).each_with_index do |e, i|
            io << ", " if i != 0
            io << "'#{e.as(String | Symbol)}'"
          end
          io << ") "
        end
        if options.has_key?(:null)
          if options[:null]
            io << " NULL"
          else
            io << " NOT NULL"
          end
        end
        io << " PRIMARY KEY" if options[:primary]?
        io << " DEFAULT #{self.class.t(options[:default])}" if options[:default]?
        io << " AUTO_INCREMENT" if options[:auto_increment]?
      end

      private def regular_query_message(query, args : Array)
        args.empty? ? query : "#{query} | #{args.inspect}"
      end

      private def regular_query_message(query, arg = nil)
        arg ? "#{query} | #{arg}" : query
      end
    end
  end
end
