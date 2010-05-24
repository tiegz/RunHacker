sudo gem install active_support hpricot json

require 'rubygems'
require 'active_support'
require 'open-uri'
require 'hpricot'
require 'pp'
require 'time'
require 'net/http'
require 'json'
require 'digest/sha1'


class RunnersWorld
  attr_reader :courses, :events
  
  def initialize(file="")
    doc = Hash.from_xml(File.open(file, 'r').read)
    
    puts
    print "Importing Runner's World Routes"
    @courses = process_courses(doc['RunningAHEADLog']['CourseCollection']['Course'])

    puts
    print "Importing Runner's World Workouts: "
    @events = process_events(doc['RunningAHEADLog']['EventCollection'])
  end
  
  def process_events(events_by_type={'Run' => [], 'Bike' => []})
    all_events = []
    events_by_type.each_pair { |type, events| 
      events = [events] unless events.is_a?(Array)
      events.each do |event|
        # RunnersWorld -> Runkeeper format
        print "."
        event['activityType'] = 'undefined'
        event['activityType'] = 'Running' if type == 'Run'
        event['activityType'] = 'Cycling' if type == 'Bike'
        event['activityType'] = 'Walking' if type == 'Generic'
        event['activityType'] = 'Swimming' if type == 'Swim'
        all_events.push(event)
      end
    }
    all_events # noop
  end
  
  def process_courses(courses=[], isRunnersWorld=true)
    courses.map { |course|
      url = "http://traininglog.runnersworld.com/maps/#{course['ID']}"
      doc = Hpricot(open(url).read)
      if map_data_input = (doc / "#MapData").attr('value')
        begin 
          map_data_decoded = URI.decode(map_data_input)
          map_data = Hash.from_xml(map_data_decoded)
          course['Points'] = map_data['Map']['Route']['Point']
        rescue => e
          puts "Error decoding the course: #{course['Name']}"
        end
      end
      print "."
      course
    }.compact
  end
end


# Used to calculate distance betwn point-to-point
def haversine_distance( lat1, lon1, lat2, lon2 )
  rad_per_deg = 0.017453293
  rmiles = 3956           # radius of the great circle in miles
  rkm = 6371              # radius in kilometers...some algorithms use 6367
  rfeet = rmiles * 5282   # radius in feet
  rmeters = rkm * 1000    # radi
  
  dlon = lon2 - lon1
  dlat = lat2 - lat1
 
  dlon_rad = dlon * rad_per_deg
  dlat_rad = dlat * rad_per_deg
 
  lat1_rad = lat1 * rad_per_deg
  lon1_rad = lon1 * rad_per_deg
 
  lat2_rad = lat2 * rad_per_deg
  lon2_rad = lon2 * rad_per_deg

  a = (Math.sin(dlat_rad/2))**2 + Math.cos(lat1_rad) * Math.cos(lat2_rad) * (Math.sin(dlon_rad/2))**2
  c = 2 * Math.atan2( Math.sqrt(a), Math.sqrt(1-a))
 
  dMi = rmiles * c          # delta between the two points in miles
  dKm = rkm * c             # delta in kilometers
  dFeet = rfeet * c         # delta in feet
  dMeters = rmeters * c     # delta in meters
 
  dMi
end


module RunHacker
  class Run
    attr_accessor :points
    def initialize(points=[])
      self.points = points
    end
    
    def add_point(point)
      self.points << point
      sort!
    end

    def sort!
      self.points = points.sort_by { |pt| pt.time }
    end
  end
  
  # Turn into Struct?
  class Point
    attr_reader :lat, :long, :alt, :time
    
    def initialize(lat="0.0", long="0.0", alt="0.0", time="")
      @lat  = lat.to_f
      @long = long.to_f
      @alt  = alt.to_f
      @time = time.is_a?(Time) ? time : Time.parse(time.to_s)
    end
  end
  
  class RunKeeper
    def initialize(email="", password="")
      @email    = email
      @password = password
      @device_id = Digest::SHA1.hexdigest("#{@email}#{@password}")
    end
    
    def import_manual_run(distanceMiles, startTime, durationSec, weight, activityType='Running')
      distanceMeters = distanceMiles.to_f * 1609.344
      uri = URI.parse('http://www.fitnesskeeperapi.com/RunKeeper/trippost/manualentry')
      params = common_params
      params['duration'] = sprintf("%.6f", durationSec)
      params['gymEquip'] = 0
      params['startTime'] = startTime.strftime("%Y/%m/%d %I:%M:%S.000")
      params['avgHeartRate'] = 0
      params['calories'] = 0
      params['weight'] = weight
      params['distance'] = sprintf("%.6f", distanceMeters)
      params['activityType'] = activityType
      res = Net::HTTP.post_form(uri, params)
      trip = JSON.parse(res.body)
    end
    
    def import_run(run, weight, activityType)
      trip = newtrip()
      run.points.each do |point|
        if point == run.points.first 
          addpoint(trip, point, "StartPoint")
        elsif point == run.points.last
          addpoint(trip, point, "EndPoint")
        else 
          addpoint(trip, point, "TripPoint")
        end
      end
    end
    
    def common_headers
      { 'Gateway-Interface' => 'CGI/1.2', 
        'Accept' => '*/*', 
        'Accept-Encoding' => 'gzip, deflate', 
        'Accept-Language' => 'en-us', 
        'Connection' => 'keep-alive', 
        'Pragma' => 'no-cache',
        'Host' => 'www.fitnesskeeperapi.com',
        'Content-Type' => 'application/x-www-form-urlencoded', # this one necessary?
        'Proxy-Connection' => 'keep-alive', 
        'User-Agent' => 'RK_Pro/2.2.0.18 CFNetwork/459 Darwin/10.0.0d3', 
        'Version' => 'HTTP/1.1' }
    end
    
    def common_params
      { 'email' => @email, 
        'password' => @password, 
        'deviceID' => @device_id, 
        'device' => 'iPhone,3.1.3',  
        'deviceApp' => 'deviceApp=paid,2.2.0.18' #'free,1.6.0.19' # or "" \
      }
    end
    
    
    def newtrip(activityType='Running')
      uri = URI.parse('http://www.fitnesskeeperapi.com:80/RunKeeper/trippost/newtrip')
      params = common_params
      params['Path-Info'] = '/RunKeeper/trippost/newtrip'
      params['activityType'] = activityType
      res = Net::HTTP.post_form(uri, params)
      trip = JSON.parse(res.body)
      trip
    end
    
    # RunKeeper's apparent time format
    def timestring(time)
      time.strftime("%Y/%m/%d %H:%M:%S") + ".#{time.usec}"[0..3]
    end
    
    def addpoint(trip, point, type_of_point)
      uri = URI.parse('http://www.fitnesskeeperapi.com/RunKeeper/trippost/addpoints')
      params = common_params
      params['tripID'] = trip['tripID'].to_s
      params['pointList'] = "#{type_of_point},#{timestring(point.time)},#{point.lat},#{point.long},0.000000,0.000000,#{point.alt};"
      res = Net::HTTP.post_form(uri, params)
    end
  end
end


if __FILE__ == $0
  if ARGV[0]
    rw = RunnersWorld.new(ARGV[0])
    puts
    ARGV.clear

    puts "***************************************************************************************************"
    puts "WARNING! This script is not supported by RunKeeper. It attempts to import your data into RunKeeper,"
    puts "but there's always a chance it may not correctly import. Run at your own risk. Press ctrl-c to exit."
    puts "***************************************************************************************************"
    print "Please enter RunKeeper email: "
    email = gets.chomp.strip
    puts
    print "Please enter RunKeeper password: "
    password = gets.chomp.strip
    puts
    rk = RunHacker::RunKeeper.new(email, password)

    rw.events.compact.each do |rwEvent|
      puts
      print "Import '#{rwEvent['activityType']}' event from #{rwEvent['Date']}? [Y/n] "
      if gets.chomp =~ /^[^nN]*$/
        run = RunHacker::Run.new
        rwCourse = rw.courses.find { |c| c['ID'] == rwEvent['CourseID'] }
        puts " -> Adding #{rwCourse.nil? || rwCourse['Points'].nil? ? 'Manual' : 'Mapped'} event from #{rwEvent['Date']}: (Total dist: #{rwEvent['Distance']} mi)"
        t, d, = rwEvent['Time'], rwEvent['Date']

        # The Start Time
        rwEventDateTime = DateTime.new(d[0..3].to_i, d[5..6].to_i, d[8..9].to_i, t[0..1].to_i, t[3..4].to_i, t[6..7].to_i)

        # The Duration
        rwDuration = (rwEvent['Duration'] || "00:01").split(':').map { |str| str.to_i }
        rwDuration.unshift(0) while rwDuration.length < 3
        rwDuration[1] += rwDuration[0] * 60 
        rwDuration[2] += rwDuration[1] * 60
        rwDuration = rwDuration[2] # (in seconds)

        if rwCourse.nil? || rwCourse['Points'].nil?
          rk.import_manual_run(rwEvent['Distance'].to_f, rwEventDateTime, rwDuration, (rwEvent['Weight'].to_f / 2.2), rwEvent['activityType'])
        else
          rwTotalDuration, rwTotalDist  = 0, 0
          rwPointLast = { 'x' => rwCourse['Points'][0]['x'], 'y' => rwCourse['Points'][0]['y'] }
          rwPace = rwDuration.to_f / rwEvent['Distance'].to_f # sec / mi

          rwCourse['Points'].each_with_index do |rwPoint, index|
            rwPointDist = haversine_distance(rwPointLast['y'].to_f, rwPointLast['x'].to_f, rwPoint['y'].to_f, rwPoint['x'].to_f)
            rwTotalDist += rwPointDist
            rwPointDuration = (rwPointDist * rwPace).seconds
            rwTotalDuration +=  rwPointDuration
            
            rwEventDateTime += rwPointDuration
            run.add_point(RunHacker::Point.new(sprintf("%.6f", rwPoint['y'].to_f), 
                                               sprintf("%.6f", rwPoint['x'].to_f), 
                                               '100', # no Altitude from RunnersWorld? Looks like set automatically
                                               rwEventDateTime.strftime("%Y/%m/%d %I:%M:%S.000")))
            
            # NOTE: we take the average pace (rwPace), apply that for every point, calculate the distance
            #       covered in each point (rwPointDist), and if the total distance covered so far (rwTotalDist) is
            #       greater than the rwEvent's distance (rwEvent['Distance']), then stop because the course must have been
            #       longer than the recorded distance for the event
            break if rwTotalDist > rwEvent['Distance'].to_f

            # Set this so we can calculate distance covered every point
            rwPointLast = { 'x' => rwPoint['x'], 'y' => rwPoint['y'] }
          end
          
          rk.import_run(run, (rwEvent['Weight'].to_f / 2.2), rwEvent['activityType'])
        end
      else
      end
    end
    puts
    puts "Done importing runs! NOTE (the distances for Mapped runs will be 0.00 until you edit them, change a single point, and save)"

    
  else
    puts
    puts "-----------------------------------------------------"
    puts "How to use this script to get your RunnersWorld data:"
    puts "-----------------------------------------------------"
    puts "  1) Login to your Training Log at Runners World: http://traininglog.runnersworld.com/routes"
    puts "  2) Select 'Tools'"
    puts "  3) Select 'Export' (in XML format), and click 'Download'"
    puts "  4) Type:  ruby runnersworld.rb /Path/To/Runners/World/Exported/file.xml"
    puts

    exit
  end
end

