require_relative 'database_rewinder/cleaner'

module DatabaseRewinder
  VERSION = Gem.loaded_specs['database_rewinder'].version.to_s

  class << self
    # Set your DB configuration here if you'd like to use something else than the AR configuration
    attr_writer :database_configuration

    def init
      @cleaners, @table_names_cache, @clean_all, @only, @except, @database_configuration = [], {}, false
    end

    def database_configuration
      @database_configuration || ActiveRecord::Base.configurations
    end

    def create_cleaner(connection_name)
      config = database_configuration[connection_name] or raise %Q[Database configuration named "#{connection_name}" is not configured.]

      Cleaner.new(config: config, connection_name: connection_name, only: @only, except: @except).tap {|c| @cleaners << c}
    end

    def [](connection)
      @cleaners.detect {|c| c.connection_name == connection} || create_cleaner(connection)
    end

    def all=(v)
      @clean_all = v
    end

    def cleaners
      create_cleaner 'test' if @cleaners.empty?
      @cleaners
    end

    def record_inserted_table(connection, sql)
      config = connection.instance_variable_get(:'@config')
      database = config[:database]
      #NOTE What's the best way to get the app dir besides Rails.root? I know Dir.pwd here might not be the right solution, but it should work in most cases...
      root_dir = defined?(Rails) ? Rails.root : Dir.pwd
      cleaner = cleaners.detect do |c|
        if (config[:adapter] == 'sqlite3') && (config[:database] != ':memory:')
          File.expand_path(c.db, root_dir) == File.expand_path(database, root_dir)
        else
          c.db == database
        end
      end or return

      match = sql.match(/\AINSERT(?:\s+IGNORE)?(?:\s+INTO)?\s+(?:\.*[`"]?([^.\s`"]+)[`"]?)*/i)
      return unless match

      table = match[1]
      if table
        cleaner.inserted_tables << table unless cleaner.inserted_tables.include? table
        cleaner.pool ||= connection.pool
      end
    end

    def clean
      if @clean_all
        clean_all
      else
        cleaners.each(&:clean)
      end
    end

    def clean_all
      cleaners.each(&:clean_all)
    end

    # cache AR connection.tables
    def all_table_names(connection)
      db = connection.pool.spec.config[:database]
      #NOTE connection.tables warns on AR 5 with some adapters
      tables = ActiveRecord::Base.logger.silence { connection.tables }
      @table_names_cache[db] ||= tables.reject do |t|
        (t == ActiveRecord::Migrator.schema_migrations_table_name) ||
        (ActiveRecord::Base.respond_to?(:internal_metadata_table_name) && (t == ActiveRecord::Base.internal_metadata_table_name))
      end
    end
  end
end

begin
  require 'rails'
  require_relative 'database_rewinder/railtie'
rescue LoadError
  DatabaseRewinder.init
  require_relative 'database_rewinder/active_record_monkey'
end
