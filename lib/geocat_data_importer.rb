require 'active_model'
require 'app/models/rlat_data'
require 'json'
require 'rchardet'
require 'csv-mapper'

module GeocatDataImporter

  def self.included(base)

    base.class_eval do
      include ActiveModel::Validations

      attr_accessor :reportName, :viewPort, :analysis, :format, :center, :sources, :layers
      attr_writer :warnings

      validate :sources_must_be_valid
    end

    base.send :include, InstanceMethods
    base.send :extend, ClassMethods

  end

  module InstanceMethods

    def initialize(data = nil)
      return if data.blank?

      case data
      when RlatData
        process_as_rla data
      else
        begin
          process_as_hash data
        rescue JSON::ParserError => e
          begin
            process_as_csv data
          rescue Exception => ex
            errors.add(:file, 'file is not valid')
          end
        end
      end
    end

    def warnings
      @warnings = {} unless @warnings
      @warnings
    end

    def to_json
      {
        :success => valid?,
        :format => format,
        :data => {
          :reportName => reportName || 'CSV file',
          :viewPort => viewPort,
          :analysis => analysis,
          :sources => sources,
          :layers => layers
        },
        :errors => errors,
        :warnings => warnings
      }.to_json
    end

    def to_csv
      return '' unless self.valid?

      data = []
      sources.each do |source|
        data += source['points'].reject{|p| p["geocat_removed"]}.collect do |point|
          {
            'recordSource'                  => point['recordSource'],
            'scientificname'                => source['query'],
            'latitude'                      => point['latitude'],
            'longitude'                     => point['longitude'],
            'changed'                       => point['changed'],
            'collector'                     => point['collector'],
            'coordinateuncertaintyinmeters' => point['coordinateUncertaintyInMeters'],
            'catalogue_id'                  => point['catalogue_id'],
            'collectionCode'                => point['collectionCode'],
            'institutionCode'               => point['institutionCode'],
            'catalogNumber'                 => point['catalogNumber'],
            'basisOfRecord'                 => point['basisOfRecord'],
            'eventDate'                     => point['eventDate'],
            'country'                       => point['country'],
            'stateProvince'                 => point['stateProvince'],
            'county'                        => point['county'],
            'verbatimElevation'             => point['verbatimElevation'],
            'locality'                      => point['locality'],
            'coordinateUncertaintyText'     => point['coordinateUncertaintyText'],
            'identifiedBy'                  => point['identifiedBy'],
            'occurrenceRemarks'             => point['occurrenceRemarks'],
            'occurrenceDetails'             => point['occurrenceDetails']
          }
        end
      end

      return if data.first.nil?

      columns = data.first.keys.sort

      output = FasterCSV.generate do |csv|
        csv << columns
        data.each do |row|
          csv << columns.collect { |column| row[column] }
        end
      end
      output
    end

    private
      def process_as_hash(data)
        hash = if data.is_a? Hash
          data
        else
          JSON.parse(data.read.gsub(/\bundefined\b/, '"Added by user"'))
        end

        self.reportName     = hash['reportName']
        self.viewPort       = hash['viewPort']
        self.format         = 'geocat'
        self.analysis       = hash['analysis']
        self.sources        = hash['sources']
        self.layers         = hash['layers']

      end

      def process_as_csv(file)
        buffer = fix_encoding(file)

        csv = CsvMapper.import(buffer, {:type => :io}) do
          read_attributes_from_file
        end
        return if csv.blank?

        self.reportName     = csv.first.reportName if csv.first.respond_to?(:reportName)
        self.zoom           = csv.first.zoom if csv.first.respond_to?(:zoom)
        self.format         = 'csv'
        self.center         = {
          "latitude"  => csv.first.respond_to?(:center_latitude)  ? csv.first.center_latitude  : nil,
          "longitude" => csv.first.respond_to?(:center_longitude) ? csv.first.center_longitude : nil
        }
        self.sources        = [{
          'name'   => 'csv',
          'type'   => 'user',
          'points' => []
        }]
        csv.each do |row|
          self.sources.first['points'].push({
            'recordSource'                  => (row.try(:recordsource)                  rescue "Added by user"),
            'latitude'                      => (row.try(:latitude)                      rescue nil),
            'longitude'                     => (row.try(:longitude)                     rescue nil),
            'collector'                     => (row.try(:collector)                     rescue nil),
            'coordinateUncertaintyInMeters' => (row.try(:coordinateuncertaintyinmeters) rescue nil),
            'catalogue_id'                  => (row.try(:catalogue_id)                  rescue nil),
            'collectionCode'                => (row.try(:collectioncode)                rescue nil),
            'institutionCode'               => (row.try(:institutioncode)               rescue nil),
            'catalogNumber'                 => (row.try(:catalognumber)                 rescue nil),
            'basisOfRecord'                 => (row.try(:basisofrecord)                 rescue nil),
            'eventDate'                     => (row.try(:eventdate)                     rescue nil),
            'country'                       => (row.try(:country)                       rescue nil),
            'stateProvince'                 => (row.try(:stateprovince)                 rescue nil),
            'county'                        => (row.try(:county)                        rescue nil),
            'verbatimElevation'             => (row.try(:verbatimelevation)             rescue nil),
            'locality'                      => (row.try(:locality)                      rescue nil),
            'coordinateUncertaintyText'     => (row.try(:coordinateuncertaintytext)     rescue nil),
            'identifiedBy'                  => (row.try(:identifiedby)                  rescue nil),
            'occurrenceRemarks'             => (row.try(:occurrenceremarks)             rescue nil),
            'occurrenceDetails'             => (row.try(:occurrencedetails)             rescue nil)
          })
        end
      end

      def process_as_rla(rla)
        self.reportName = rla.scientificname
        self.viewPort = {
          'zoom' => rla.zoom,
          'center' => rla.center
        }
        self.sources = rla.sources.map do |source|
          {
            "type" => source["name"],
            "query" => rla.scientificname,
            "points" => source["points"].map do |point|
              point_hash = point.slice(
                "ocurrenceDetails",
                "latitude",
                "collector",
                "country",
                "collectionCode",
                "ocurrenceRemarks",
                "catalogNumber",
                "county",
                "stateProvince",
                "locality",
                "recordedBy",
                "catalogue_id",
                "basisOfRecord",
                "longitude",
                "coordinateUncertaintyMeters",
                "institutionCode",
                "eventDate",
                "verbatimElevation"
              )
              point_hash["geocat_active"] = point["active"]
              point_hash["geocat_query"] = rla.scientificname
              point_hash["geocat_kind"] = point["kind"]
              point_hash["geocat_removed"] = point["removed"]
              point_hash
            end
          }
        end
        self.analysis = {
          'AOO' => rla.analysis.slice(*%w(cellsize_type cellsize cellsize_step))
        } if rla.analysis.present?
      end

      def sources_must_be_valid
        invalid_points   = []
        sources_errors   = []
        sources_warnings = []

        if self.sources.present?
          self.sources.each do |source|
            sources_errors << 'you must provide a valid source type' if source['type'].blank?
            source['points'].each do |point|
              if point['latitude'].blank? || point['longitude'].blank?
                 invalid_points.push(point)
              end
            end
            if invalid_points.present?
              source['points'] = source['points'] - invalid_points
              if source['points'].blank?
                sources_errors << 'you must provide at least one point with valid latitude and longitude fields'
              else
                sources_warnings << "#{invalid_points.length} records were not imported because they were missing mandatory fields."
              end
            end
            removed_dupes = Hash[source['points'].select{|x| x['catalogue_id'].present?}.map{|x| [x['catalogue_id'], x]}].values || []
            if removed_dupes.present? && source['points'].length > removed_dupes.length
              source['points'] = source['points'] - removed_dupes
              sources_warnings << "#{source['type']} source has duplicated catalogue_id's"
            end
          end
        else
          sources_errors << 'you must provide at least one point with valid latitude and longitude fields'
        end
        warnings[:sources] = sources_warnings if sources_warnings.present?
        errors.add(:sources, sources_errors) if sources_errors.present?
      end

      def fix_encoding(file)
        buffer = file

        buffer.rewind if buffer.respond_to?(:rewind)
        buffer = StringIO.new(file.read) if file.respond_to?(:read)

        buffer_encoding = CharDet.detect(buffer.read).try(:[], 'encoding')
        buffer.rewind
        StringIO.new(Iconv.conv('utf-8', buffer_encoding, buffer.read)) rescue nil
      end
      private :fix_encoding

    end

    module ClassMethods

    end

end
