require 'fileutils'
require 'time'
require 'fakes3/s3_object'
require 'fakes3/bucket'
require 'fakes3/rate_limitable_file'
require 'digest/md5'
require 'yaml'

module FakeS3
  class FileStore
    SHUCK_METADATA_DIR = ".fakes3_metadataFFF"

    def initialize(root)
      @root = root
      @buckets = []
      @bucket_hash = {}
      Dir[File.join(root,"*")].each do |bucket|
        bucket_name = File.basename(bucket)
        bucket_obj = Bucket.new(bucket_name,Time.now,[])
        @buckets << bucket_obj
        @bucket_hash[bucket_name] = bucket_obj
      end
    end

    # Pass a rate limit in bytes per second
    def rate_limit=(rate_limit)
      if rate_limit.is_a?(String)
        if rate_limit =~ /^(\d+)$/
          RateLimitableFile.rate_limit = rate_limit.to_i
        elsif rate_limit =~ /^(.*)K$/
          RateLimitableFile.rate_limit = $1.to_f * 1000
        elsif rate_limit =~ /^(.*)M$/
          RateLimitableFile.rate_limit = $1.to_f * 1000000
        elsif rate_limit =~ /^(.*)G$/
          RateLimitableFile.rate_limit = $1.to_f * 1000000000
        else
          raise "Invalid Rate Limit Format: Valid values include (1000,10K,1.1M)"
        end
      else
        RateLimitableFile.rate_limit = nil
      end
    end

    def buckets
      @buckets
    end

    def get_bucket_folder(bucket)
      File.join(@root,bucket.name)
    end

    def get_bucket(bucket)
      @bucket_hash[bucket]
    end

    def get_sorted_object_list(bucket)
      list = SortedObjectList.new
      for object in get_objects_under_path(bucket, "")
        list.add(object)
      end
      return list
    end

    def get_objects_under_path(bucket, path)
      objects = []
      current = File.join(@root, bucket.name, path)
      Dir.entries(current).each do |file|
        next if file =~ /^\./
        if path.empty?
          new_path = file
        else
          new_path = File.join(path, file)
        end
        if File.directory?(File.join(current, file, SHUCK_METADATA_DIR))
          objects.push(get_object(bucket.name, new_path, ""))
        else
          objects |= get_objects_under_path(bucket, new_path)
        end
      end

      return objects
    end
    private :get_objects_under_path

    def create_bucket(bucket)
      FileUtils.mkdir_p(File.join(@root,bucket))
      bucket_obj = Bucket.new(bucket,Time.now,[])
      if !@bucket_hash[bucket]
        @buckets << bucket_obj
        @bucket_hash[bucket] = bucket_obj
      end
      bucket_obj
    end

    def delete_bucket(bucket_name)
      bucket = get_bucket(bucket_name)
      raise NoSuchBucket if !bucket
      raise BucketNotEmpty if bucket.objects.count > 0
      FileUtils.rm_r(get_bucket_folder(bucket))
      @bucket_hash.delete(bucket_name)
    end

    def get_object(bucket_name,object_name, request)
      begin
        real_obj = S3Object.new
        obj_root = File.join(@root,bucket_name,object_name,SHUCK_METADATA_DIR)
        metadata = YAML.load_file(File.join(obj_root,"metadata"))
        real_obj.name = object_name
        real_obj.md5 = metadata[:md5]
        real_obj.content_type = metadata.fetch(:content_type) { "application/octet-stream" }
        #real_obj.io = File.open(File.join(obj_root,"content"),'rb')
        real_obj.io = RateLimitableFile.new(File.join(obj_root,"content"))
        real_obj.size = metadata.fetch(:size) { 0 }
        real_obj.creation_date = File.ctime(obj_root).iso8601()
        real_obj.modified_date = metadata.fetch(:modified_date) { File.mtime(File.join(obj_root,"content")).iso8601() }
        return real_obj
      rescue
        puts $!
        $!.backtrace.each { |line| puts line }
        return nil
      end
    end

    def object_metadata(bucket,object)
    end

    def copy_object(src_bucket_name,src_name,dst_bucket_name,dst_name)
      obj = nil
      if src_bucket_name == dst_bucket_name && src_name == dst_name
        # source and destination are the same, nothing to do but
        # find current object so it can be returned
        obj = src_bucket.find(src_name)
      else
        src_root = File.join(@root,src_bucket_name,src_name,SHUCK_METADATA_DIR)
        dst_root = File.join(@root,dst_bucket_name,dst_name,SHUCK_METADATA_DIR)

        FileUtils.mkdir_p(dst_root)
        FileUtils.copy_file(File.join(src_root,"content"),File.join(dst_root,"content"))
        FileUtils.copy_file(File.join(src_root,"metadata"), File.join(dst_root,"metadata"))

        dst_bucket = self.get_bucket(dst_bucket_name)
        dst_bucket.add(get_object(dst_bucket.name, dst_name, ""))
      end
      return obj
    end

    def store_object(bucket,object_name,request)
      begin
        filename = File.join(@root,bucket.name,object_name)
        FileUtils.mkdir_p(filename)

        metadata_dir = File.join(filename,SHUCK_METADATA_DIR)
        FileUtils.mkdir_p(metadata_dir)

        content = File.join(filename,SHUCK_METADATA_DIR,"content")
        metadata = File.join(filename,SHUCK_METADATA_DIR,"metadata")

        md5 = Digest::MD5.new
        # TODO put a tmpfile here first and mv it over at the end

        File.open(content,'wb') do |f|
          request.body do |chunk|
            f << chunk
            md5 << chunk
          end
        end

        metadata_struct = {}
        metadata_struct[:md5] = md5.hexdigest
        metadata_struct[:content_type] = request.header["content-type"].first
        metadata_struct[:size] = File.size(content)
        metadata_struct[:modified_date] = File.mtime(content).iso8601()

        File.open(metadata,'w') do |f|
          f << YAML::dump(metadata_struct)
        end

        obj = S3Object.new
        obj.name = object_name
        obj.md5 = metadata_struct[:md5]
        obj.content_type = metadata_struct[:content_type]
        obj.size = metadata_struct[:size]
        obj.creation_date = File.ctime(metadata_dir)
        obj.modified_date = metadata_struct[:modified_date]

        bucket.add(obj)
        return obj
      rescue
        puts $!
        $!.backtrace.each { |line| puts line }
        return nil
      end
    end

    def delete_object(bucket,object_name,request)
      begin
        filename = File.join(@root,bucket.name,object_name)
        FileUtils.rm_rf(filename)
        object = bucket.find(object_name)
        bucket.remove(object)
      rescue
        puts $!
        $!.backtrace.each { |line| puts line }
        return nil
      end
    end
  end
end
