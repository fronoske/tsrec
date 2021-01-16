#!/usr/bin/env ruby
#;;; -*- coding: utf-8; tab-width: 2; -*-

# TODO
# tsrec status または ps で現在の状況を表示する
# outdir をカスタム化
# SQLiteにEPG保存し、無視条件を SQL で指定できるようにする
# サービスIDでなくチャンネル指定で複数局録画 → 無理っぽい

require 'open-uri'
require 'json'
require 'awesome_print'
require 'logger'
require 'optparse'
require 'fileutils'
require 'tmpdir'
require 'time'
require 'yaml'
require 'pry'

SCRIPT_PATH = File.expand_path($0)
SCRIPT_NAME = File.basename($0, ".*")
PID_PATH = File.expand_path("../.pid", $0)
TSREC_UA = "tsrec pid=#{Process.pid}"
CURL_UA = "curl pid=#{Process.pid}"
DEFAULT_MIRAKC_HOST = 'localhost'
DEFAULT_MIRAKC_PORT = 40772
DEFAULT_MARGIN_SEC = 5
DEFAULT_OUTFILE_FORMAT = "%Y%m%d_%H%M %%T.ts"
MARGIN_SEC_FOR_NEXT_REC = 60 # 番組終了 n 秒前に次の番組のEPG情報を取得する
RE_IGNORE_LIST = [/^放送(休止|終了)$/, /^休止$/]

##################
# Classes
##################
module Mirakc
  def self.base_url
    "http://#{$config.mirakc_host}:#{$config.mirakc_port}/api"
  end
  
  def self.read(url)
    URI.open(url, "r:utf-8", {"User-Agent" => TSREC_UA}).read
  end
  
  def self.get_version
    JSON.parse self.read("#{self.base_url}/version")
  rescue
    nil
  end
  
  def self.read_channels
    self.read("#{self.base_url}/channels")
  end
  
  def self.read_programs
    self.read("#{self.base_url}/programs")
  end
  
  def self.url_program(program_id)
    "#{self.base_url}/programs/#{program_id}"
  end
  
  def self.rec_command(program_id, full_path)
    command = case [!$config.no_ts, $config.pipe_command.is_a?(String)]
    when [true, true] # ファイル出力 & パイプあり
      %Q!curl -sSL -A '#{CURL_UA}' #{self.url_program(program_id)}/stream | tee '#{full_path}' | #{$config.pipe_command}!
    when [true, false] # ファイル出力 & パイプなし
      %Q!curl -sSL -A '#{CURL_UA}' #{self.url_program(program_id)}/stream -o '#{full_path}'!
    when [false, true] # ファイル出力なし & パイプあり
      %Q!curl -sSL -A '#{CURL_UA}' #{self.url_program(program_id)}/stream | #{$config.pipe_command}!
    else # [true, false]
      raise "予期しないエラー： -n なのに -p がない"
    end
    command
  end
end

class Config
  attr_accessor :config_yml, :service_id, :margin_sec, :out_dir, :outfile_format, :no_ts, 
  :output_json, :output_text, :pipe_command, :following_command, :logfile, :loglevel,
  :mirakc_host, :mirakc_port, :subcommand, :section, :opts
  
  def initialize
    @opts = OptionParser.new
    parse_options
  end
  
  def to_json
    self.instance_variables.reject{|_var| _var == :@opts}.map{|_var|
      [_var, instance_variable_get(_var)]
    }.to_h.to_json
  end
  
  def parse_options
    @opts.banner = "USAGE: #{$0} (start|stop|status|ps|list) [section] [options...]"
    @opts.on("-c config.yml",       String,    "configuration file (default: #{SCRIPT_NAME}.yml)"){|v| @config_yml = v}
    @opts.on("-s serviceId",        Integer,   "service ID"){|v| @service_id = v}
    @opts.on("-m marginSec",        Numeric,   "margin sec to rec [0-15] (default: #{DEFAULT_MARGIN_SEC})"){|v| @margin_sec = v }
    @opts.on("-o outDir",           String,    "output directory (default: $TEMP/tsrec"){|v| @out_dir = v}
    @opts.on("-f outfileFormat",    String,    "TS file format (default: #{DEFAULT_OUTFILE_FORMAT})"){|v| @outfile_format = v }
    @opts.on("-n",                  TrueClass, "not output TS file"){|v| @no_ts = v }
    @opts.on("-j",                  TrueClass, "output program information JSON file"){|v| @output_json = v }
    @opts.on("-t",                  TrueClass, "output program information TEXT file"){|v| @output_text = v }
    @opts.on("-p command",          String,    "pipe command"){|v| @pipe_command = v }
    @opts.on("-a command",          String,    "command following each rec"){|v| @following_command = v }
    @opts.on("-l logfile",          String,    "output log (default: stdout)"){|v| @logfile = v }
    @opts.on("-v loglevel",         String,    "loglevel [fatal(0)|error(1)|warn(2)|info(3)|debug(4)|max(5)] (default:info)"){|v| @loglevel = v }
    @opts.on("-u host:port",        String,    "mirakurun/mirakc host:port (default: #{DEFAULT_MIRAKC_HOST}:#{DEFAULT_MIRAKC_PORT})"){|v| @mirakc_host, @mirakc_port = v.split(":") }
    @opts.parse!(ARGV)
    @subcommand = ARGV[0]
    @section = ARGV[1]
  end
  
  def check_config
    load_config_from_yml
    @margin_sec     ||= DEFAULT_MARGIN_SEC
    @outfile_format ||= DEFAULT_OUTFILE_FORMAT
    @mirakc_host    ||= DEFAULT_MIRAKC_HOST
    @mirakc_port    ||= DEFAULT_MIRAKC_PORT
    @out_dir        ||= File.join(Dir.tmpdir, "tsrec")
    @out_dir = File.expand_path(@out_dir)
    
    $log = Logger.new(@logfile || $stdout)
    $log.level = case @loglevel.to_s.downcase
    when 'fatal', '0' then Logger::FATAL
    when 'error', '1' then Logger::ERROR
    when 'warn',  '2' then Logger::WARN
    when 'debug', '4', 'max', '5' then Logger::DEBUG
    else Logger::INFO
    end
    $log.formatter = proc{|severity, datetime, progname, message|
      "[%s] [%s] %s\n" % [datetime.strftime('%H:%M:%S'), severity, message ]
    }

    mirakc_version = Mirakc::get_version
    if mirakc_version
      $log.debug "Mirakurun/Mirakc Version #{mirakc_version}"
    else
      abort "[FATAL] Mirakurun/Mirakcサーバーにアクセスできません"
    end
    
    if @service_id.nil?
      $stderr.puts opts.help
      $stderr.puts
      abort "[FATAL] サービスIDの指定は必ず必要です"
    end
  
    if @margin_sec < 0 || 15 < @margin_sec
      $stderr.puts opts.help
      $stderr.puts
      abort "[FATAL] marginSec は 0～15 で指定してください"
    end
  
    if @no_ts && @pipe_command.nil?
      $stderr.puts opts.help
      $stderr.puts
      abort "[FATAL] -n のときは -p を必ず指定する必要があります"
    end
  end
  
  # yaml から config をロードする。コマンドラインオプションで指定されていればそちらを優先する
  def load_config_from_yml
    @config_yml ||= File.expand_path("../#{SCRIPT_NAME}.yml", SCRIPT_PATH)
    config_yaml = YAML.load_file(@config_yml)
    if config_yaml[@section].nil?
      abort "Section '#{@section}' not found in #{@config_yml}"
    end
    config = config_yaml["common"].to_h.merge(config_yaml[@section].to_h)
    @service_id        ||= config["serviceId"]
    @margin_sec        ||= config["marginSec"]
    @out_dir           ||= config["outDir"]
    @outfile_format    ||= config["outFileFormat"]
    @no_ts             ||= config["noTS"]
    @output_json       ||= config["outJson"]
    @output_text       ||= config["outText"]
    @pipe_command      ||= config["pipeCommand"]
    @following_command ||= config["followingCommand"]
    @logfile           ||= config["logFile"]
    @loglevel          ||= config["logLevel"]
    @mirakc_host       ||= config["server"]&.split(":")&.first
    @mirakc_port       ||= config["server"]&.split(":")&.last
    return true
  rescue
    abort "Faild to load section #{@section} in #{@config_yml}."
  end
  
  def exec_subcommand
    case @subcommand.to_s
    when 'start'
      if @section.nil?
        $stderr.puts opts.help
        abort "セクション名が必要です"
      else
        return
      end
    when 'stop'
      if @section.nil?
        $stderr.puts "You should specify name."
        show_process_list(@section)
      else
        stop_process(@section)
      end
    when 'ps', 'status'
      show_process_list(@section)
    when 'list' # ここだけ第2引数（@section）は放送種別
      services = get_services
      show_services_list(services, @section)
    else
      $stderr.puts @opts.help
      abort "サブコマンドが不正です"
    end
    exit
  end
end

class Program
  attr_accessor :env, :pid, :end_at
  
  def initialize(hash)
    @title = hash[:name]
    @start_at = Time.at(hash[:startAt]/1000)
    @start_at_s = @start_at.strftime("%Y-%m-%d %H:%M:%S")
    @rec_start_at = @start_at - $config.margin_sec
    @rec_start_at_s = @rec_start_at.strftime("%Y-%m-%d %H:%M:%S")
    @duration = hash[:duration] / 1000
    @end_at = @start_at + @duration
    @end_at_s = @end_at.strftime("%Y-%m-%d %H:%M:%S")
    @program_id = hash[:id]
    @event_id = hash[:eventId]
    @service_id = hash[:serviceId]
    @network_id = hash[:networkId]
    @service_name = SERVICE[:name]
    @service_channel = SERVICE[:channel]
    @service_type    = SERVICE[:type]
    @desc       = hash[:description]
    @extended   = hash[:extended]&.map{|k, v| "#{k}：#{v}"}&.join("\n")
    
    @video_sc   = hash.dig(:video, :streamContent)
    @video_ct   = hash.dig(:video, :componentType)
    @video_ct_s = ARIB_TABLE.dig("ComponentType", @video_sc, @video_ct)
    @video_type = hash.dig(:video, :type).upcase
    @audio_ct   = hash.dig(:audio, :componentType)
    @audio_ct_s = ARIB_TABLE.dig("ComponentType", 2, @audio_ct)
    @audio_sampling_rate = hash.dig(:audio, :samplingRate)
    @genres     = hash.dig(:genres).map{|g| [ g[:lv1], g[:lv2] ]}
    @genres_s   = @genres.map{|g| [ARIB_TABLE.dig("ContentType", g[0], "name"), ARIB_TABLE.dig("ContentType", g[0], g[1])]}
    
    unless set_path
      $log.error "[FATAL] 出力パスを設定できませんでした: #{@full_path}"
      abort "[FATAL] 出力パスを設定できませんでした: #{@full_path}"
    end
    # $log.debug "File: #{@file_name}"
    @command = Mirakc::rec_command(@program_id, @full_path)
    @env = get_tsrec_env
    $log.debug JSON.pretty_generate(@env) if $config.loglevel =~ /^(max|5)$/
    # show_info
  end
  
  def now_on_air?
    (@start_at .. @end_at).include?(Time.now)
  end
  
  def get_tsrec_env
    {
      "TSREC_TITLE" => @title.to_s,
      "TSREC_START_AT" => @start_at.iso8601,
      "TSREC_START_AT_Y" => @start_at.year.to_s,
      "TSREC_START_AT_M" => @start_at.month.to_s,
      "TSREC_START_AT_M2" => @start_at.strftime("%m"),
      "TSREC_START_AT_D" => @start_at.day.to_s,
      "TSREC_START_AT_D2" => @start_at.strftime("%d"),
      "TSREC_START_AT_W" =>  @start_at.wday.to_s, # 0(Sun) - 6(Sat)
      "TSREC_START_AT_H" => @start_at.hour.to_s,
      "TSREC_START_AT_H2" => @start_at.strftime("%H"),
      "TSREC_START_AT_MIN" => @start_at.min.to_s,
      "TSREC_START_AT_MIN2" => @start_at.strftime("%M"),
      "TSREC_END_AT" => @end_at.iso8601,
      "TSREC_END_AT_Y" => @end_at.year.to_s,
      "TSREC_END_AT_M" => @end_at.month.to_s,
      "TSREC_END_AT_M2" => @end_at.strftime("%m"),
      "TSREC_END_AT_D" => @end_at.day.to_s,
      "TSREC_END_AT_D2" => @end_at.strftime("%d"),
      "TSREC_END_AT_W" =>  @end_at.wday.to_s, # 0(Sun) - 6(Sat)
      "TSREC_END_AT_H" => @end_at.hour.to_s,
      "TSREC_END_AT_H2" => @end_at.strftime("%H"),
      "TSREC_END_AT_MIN" => @end_at.min.to_s,
      "TSREC_END_AT_MIN2" => @end_at.strftime("%M"),
      "TSREC_DURATION_SEC" => @duration.to_s,
      "TSREC_PROGRAM_ID" => @program_id.to_s,
      "TSREC_EVENT_ID" => @event_id.to_s,
      "TSREC_SERVICE_ID" => @service_id.to_s,
      "TSREC_SERVICE_NAME" => @service_name.to_s,
      "TSREC_SERVICE_CHANNEL" => @service_channel.to_s,
      "TSREC_SERVICE_TYPE" => @service_type.to_s,
      "TSREC_NETWORK_ID" => @network_id.to_s,
      "TSREC_DESC" => @desc.to_s,
      "TSREC_EXTENDED" => @extended.to_s.to_json.gsub(/^"|"$/, ''),
      "TSREC_OUT_PATH" => @full_path.to_s,
      "TSREC_OUT_PATH_BASE" => @full_path.to_s.gsub(/\..+?$/, ''),
      "TSREC_OUT_DIR" => File.dirname(@full_path),
      "TSREC_OUT_BASE" => File.basename(@file_name, ".*"),
      "TSREC_OUT_EXT" => File.extname(@file_name),
      "TSREC_VIDEO_STREAM" => @video_sc.to_s,
      "TSREC_VIDEO_COMPONENT"  => @video_ct.to_s,
      "TSREC_VIDEO_COMPONENT_S"  => @video_ct_s.to_s,
      "TSREC_VIDEO_TYPE" => @video_type.to_s,
      "TSREC_AUDIO_COMPONENT" => @audio_ct.to_s,
      "TSREC_AUDIO_COMPONENT_S" => @audio_ct_s.to_s,
      "TSREC_AUDIO_SAMPLING_RATE" => @audio_sampling_rate.to_s,
      "TSREC_GENRE1"    => @genres_s.dig(0, 0).to_s,
      "TSREC_GENRE1SUB" => @genres_s.dig(0, 1).to_s,
      "TSREC_GENRE2"    => @genres_s.dig(1, 0).to_s,
      "TSREC_GENRE2SUB" => @genres_s.dig(1, 1).to_s,
      "TSREC_GENRE3"    => @genres_s.dig(2, 0).to_s,
      "TSREC_GENRE3SUB" => @genres_s.dig(2, 1).to_s,
      "TSREC_GENRE4"    => @genres_s.dig(3, 0).to_s,
      "TSREC_GENRE4SUB" => @genres_s.dig(3, 1).to_s,
    }
  end
  
  def set_path
    format_base = File.basename($config.outfile_format, ".*")
    format_ext  = File.extname($config.outfile_format)
    format_base  = "#{format_base}[rec=#{Time.now.strftime('%H%M')}]" if now_on_air?
    @out_dir = @start_at.strftime($config.out_dir).gsub('%T', @title)
    @out_dir = File.expand_path(@out_dir)
    FileUtils.mkdir_p(@out_dir) unless File.directory?(@out_dir)
    
    0.upto(999) do |idx|
      postfix = (idx == 0) ? "" : "(#{idx})"
      format = "#{format_base}#{postfix}#{format_ext}"
      @file_name = @start_at.strftime(format).gsub('%T', @title)
      @file_name = sanitize(@file_name)
      @full_path = File.join(@out_dir, @file_name)
      return true unless File.exist?(@full_path)
    end
    return false
  end
  
  # 録画を待機する
  def wait_rec_start
    sec_to_rec_start = [0, @rec_start_at - Time.now ].max
    $log.info "現在の番組の終了直前．次の番組の録画を準備します"
    $log.info "次の番組：#{@start_at_s}「#{@title}」（#{sec2hhmmss(@duration)}）"
    $log.info "録画を待機します（録画開始時刻：#{@rec_start_at_s}．待ち時間：#{sec2hhmmss(sec_to_rec_start.to_i)}）"
    # $log.debug "コマンド：#{@command}"
    sleep(sec_to_rec_start)
  end
  
  # 録画を実行する
  def do_rec
    @pid = spawn(@env, @command)
    # $log.info "番組開始 #{$config.margin_sec} 秒前．録画を開始しました (pid #{@pid})"
    $log.info "録画を開始しました (pid #{@pid})"
    $log.debug @command
    # $log.debug "Path: #{@full_path}"
  rescue
    $log.error "[FATAL] curlコマンドの呼び出しに失敗しました。終了します。"
    $log.error $!
    $log.error $!.backtrace
    abort "[FATAL] curlコマンドの呼び出しに失敗しました。終了します。"
  end
  
  # 録画終了の寸前まで待つ
  def wait_rec_end
    sec_to_rec_end = [0, @end_at - MARGIN_SEC_FOR_NEXT_REC - Time.now].max
    # $log.info "終了#{MARGIN_SEC_FOR_NEXT_REC}秒前に次の録画を準備します"
    $log.info "現在の番組の終了を待機します（終了予定：#{@end_at_s}．待ち時間：#{sec2hhmmss(sec_to_rec_end.to_i)}）"
    sleep(sec_to_rec_end)
  end
  
  def generate_program_info
    return nil unless @full_path
    if $config.output_json
      hash = @env.merge({"TSREC_EXTENDED" => @extended.to_s})
      hash.delete_if{|k, v| k.match?(/TSREC_(START|END)_AT_[^W]/)}
      hash.transform_keys!{|k| k[/TSREC_(.+)$/, 1]}
      json_body = JSON.pretty_generate(hash)
      json_path = @full_path.gsub(/\..+?$/, '.json')
      open(json_path, "w"){|f| f.puts json_body}
    end
    if $config.output_text
      lines = []
      lines << "#{to_j(@start_at, @end_at)} (#{sec2hhmmss(@duration)})"
      lines << "#{@service_name}"
      lines << "#{@title}"
      lines << ""
      if @desc
        lines << "#{@desc}"
        lines << ""
      end
      if @extended
        lines << "【詳細情報】"
        lines << "#{@extended}"
        lines << ""
      end
      lines << "【ジャンル】"
      lines << @genres_s.map{|genre_mainsub| genre_mainsub.join(" - ")}.join("\n")
      lines << ""
      lines << "映像：#{@video_ct_s}"
      lines << "音声：#{@audio_ct_s}"
      lines << "サンプリングレート：#{@audio_sampling_rate}"
      lines << ""
      lines << "NetworkId: #{@network_id}"
      lines << "ServiceId: #{@service_id}"
      lines << "EventId: #{@event_id}"
      text_body = lines.map(&:strip).join("\n")
      text_path = @full_path.gsub(/\..+?$/, '.txt')
      open(text_path, "w"){|f| f.puts text_body}
    end
  end
  
  ##########################################################
  # Utility関数
  ##########################################################
 
  # 番組情報の放送時間部を生成する
  def to_j(start_at, end_at)
    wday_j = "日月火水木金土"[start_at.wday]
    start_s = start_at.strftime("%Y/%m/%d(#{wday_j}) %H:%M")
    end_s = end_at.strftime("%H:%M")
    if start_at.day != end_at.day
      if end_at.hour < 6
        end_s.gsub!(/^\d\d:/, "#{end_at.hour + 24}:")
      else
        wday_j = "日月火水木金土"[end_at.wday]
        end_s = end_at.strftime("%Y/%m/%d(#{wday_j}) %H:%M")
      end
    end
    "#{start_s}～#{end_s}"
  end

  # Windows のファイル名に使用できない文字を全角にする。「！」は使用できるが「？」とのバランスのため。
  def sanitize(str)
    str.tr('\\\/:*!?"<>|', '￥／：＊！？＜＞｜')
  end 

  # インスタンス変数とその値をDebugログに出力する
  def show_info
    self.pretty_print_instance_variables.each do |_var|
      _val = instance_variable_get(_var)
      $log.debug "<#{_var}> #{_val}"
    end
  end
end

##################
# Functions
##################
# 秒を時分秒に変換する
def sec2hhmmss(sec)
  "%02d:%02d:%02d" % [sec/3600, (sec%3600)/60, sec%60]
end

# 秒を日時分秒に変換する
def sec2dddhhmmss(sec)
  "%3dd %02d:%02d:%02d" % [sec/(3600*24), (sec%(3600*24))/3600, (sec%3600)/60, sec%60]
end

def get_future_programs(service_id, time=Time.now)
  unix_time = time.to_i # unix_time は sec、番組のタイムスタンプは msec
  programs = JSON.parse(Mirakc::read_programs, symbolize_names: true)
  programs_by_service = programs.select{|prog| prog[:serviceId] == service_id}
  future_programs = programs_by_service.reject{|prog| prog[:startAt] + prog[:duration] < unix_time * 1000}
  future_programs.reject!{|prog| prog[:name] =~ Regexp.union(*RE_IGNORE_LIST)}
  future_programs.sort_by!{|prog| prog[:startAt]}
  # 終了間際なら現番組はスキップする
  if (unix_time + MARGIN_SEC_FOR_NEXT_REC + 5) * 1000 > future_programs.first[:startAt] + future_programs.first[:duration]
    future_programs.shift
  end
  future_programs
rescue
  $log.fatal "番組リストの取得に失敗しました。終了します。"
  $log.debug $!
  $log.debug $!.backtrace
  abort
end

def get_services
  # channels.json はそうそう変わるものでないからローカルに保存しておく
  channels_json = File.expand_path("../channels.json", SCRIPT_PATH)
  unless File.exist?(channels_json)
    open(channels_json, "wb"){|f| f.write Mirakc::read_channels }
  end
  channels = JSON.parse(open(channels_json, "r:utf-8").read, symbolize_names: true)
  channels.map{|c|
  type = c[:type]
  ch   = c[:channel]
    c[:services].map{|s| s.merge({type: type, channel: ch})}
  }.flatten.uniq.sort_by{|s| [['GR', 'BS', 'CS'].index(s[:type]), s[:serviceId]]}
rescue
  $log.warn "サービス一覧の取得に失敗しました。終了します。"
  $log.debug $!
  $log.debug $!.backtrace
  abort
end

def get_arib_table
  arib_yaml = File.expand_path("../arib-constants.yaml", SCRIPT_PATH)
  if File.exist?(arib_yaml)
    YAML.load_file(arib_yaml)
  else
    {}
  end
end

###########################################
# 録画以外のコマンド
###########################################
def show_services_list(services, target_type)
  target_type = target_type.to_s.upcase
  # 文字列の表示幅
  w = -> s { s.codepoints.inject(0) { |a, e| a + (e < 256 ? 1 : 2) } }
  puts "サービス名           サービスID  タイプ   物理ch"
  services.select{|sv| target_type.empty? || target_type == 'ALL' || sv[:type] == target_type}.each do |sv|
    id   = sv[:id]
    name = sv[:name]
    sid  = sv[:serviceId].to_s
    type = sv[:type]
    ch   = sv[:channel].to_s
    padding = " " * (22 - w[name])
    puts "%s  %5s      %2s    %6s" % ["#{name}#{padding}", sid, type, ch, id]
  end
  puts "サービス名           サービスID  タイプ   物理ch"
  puts
end

=begin
.pid のフォーマット
PID<tab>section<tab>実行開始日時(ISO8601)<tab>引数リストJSON
=end
def get_process_list(target_section=nil)
  info = []
  unless File.size?(PID_PATH)
    $stderr.puts "No #{SCRIPT_NAME} process"
    abort
  end
  open(PID_PATH).readlines.each do |line|
    if target_section.nil? || line.match?(/\t#{target_section}/)
      pid, section, start_time, opts = line.chomp.split("\t")
      info << { section: section, pid: pid.to_i, opts: opts, start_time: Time.iso8601(start_time)}
    end
  end
  info
end

def show_process_list(section)
  process_list = get_process_list(section)
  if section
    process = process_list.first
    puts "[#{process[:section]}]"
    puts "PID: #{process[:pid]}"
    puts "Start Time: #{process[:start_time]}"
    elapsed_sec = Time.now - process[:start_time]
    puts "Duration: #{sec2hhmmss(elapsed_sec)}"
    child_process_full =  `pgrep -P #{process[:pid]} -a`
    puts "Child: #{child_process_full}"
    puts "Config: #{JSON.pretty_generate JSON.parse(process[:opts])}"
  else
    puts "    PID        TIME     SECTION"
    process_list.each do |_p|
      elapsed_sec = Time.now - _p[:start_time]
      puts "%7s  %13s  %-7s" % [_p[:pid], sec2dddhhmmss(elapsed_sec), _p[:section]]
    end
  end
rescue
  $stderr.puts "Failed to parse #{PID_PATH}"
  $stderr.puts $!
end

def stop_process(section)
  process_info = get_process_list(section).first
  if process_info.nil?
    abort "No such process"
  end
  pid = process_info[:pid]
  pgid = Process.getpgid(pid)
  # この pidDを殺す
  Process.kill("-KILL", pgid)
  $stderr.puts "Killed processes (pgrp #{pgid})\n"
  lines = open(PID_PATH).lines.reject{|line| line.match?(/^#{pid}\t#{section}/)}
  open(PID_PATH, "wb"){|f|
    f.write lines.join("")
  }
end

###########################
# Start Here
###########################
$config = Config.new
$config.exec_subcommand
$config.check_config

Process.daemon

=begin
.pid のフォーマット
PID<tab>section<tab>実行開始日時(ISO8601)<tab>引数リストJSON
=end
open(PID_PATH, "a"){|f|
  f.puts "#{Process.pid}\t#{$config.section}\t#{Time.now.iso8601}\t#{$config.to_json}"
}

ARIB_TABLE = get_arib_table
SERVICES = get_services
SERVICE = SERVICES.find{|s| s[:serviceId] == $config.service_id}
if SERVICE
  $log.info "-" * 100
  $log.info "#{SERVICE[:name]} (#{SERVICE[:type]}/#{SERVICE[:channel]}) を全録します"
  $log.info "-" * 100
else
  $log.error "[FATAL] 指定されたサービスが見つかりません。終了します。"
  abort "[FATAL] 指定されたサービスが見つかりません。終了します。"
end

prev_curl_pid = nil
prev_program_env = nil
while(true) do
  # 現在（または次）の番組
  programs_hash = get_future_programs($config.service_id)
  if programs_hash.to_a.empty?
    $log.fatal "指定されたサービスの番組情報を取得できませんでした"
    abort
  end
  program = Program.new(programs_hash.first)
  # 放送中でなければ（すなわち program が次の番組を指しているなら）放送開始 $config.margin_sec 秒前まで待つ
  program.wait_rec_start unless program.now_on_air?
  
  # ここに来るのは、放送中または放送開始 $config.margin_sec 秒前のはず
  # 録画開始
  program.do_rec
  # 前の番組の録画プロセスの終了を待つ
  if prev_curl_pid
    $log.info "前の番組の録画プロセス(pid #{prev_curl_pid}) の終了を待ちます"
    begin
      Process.waitpid(prev_curl_pid)
      $log.info "前の番組の録画プロセスが正常終了しました (#{Process.last_status})"
    rescue
      $log.warn "前の番組の録画プロセスはすでに終了していました（異常終了？）"
    ensure
      if $config.following_command
        pid = spawn(prev_program_env, $config.following_command)
        $log.info "録画後コマンドを呼び出しました (pid #{pid})"
        $log.debug $config.following_command
        Process.detach(pid)
      end
    end
  end
  # 番組情報を出力する
  program.generate_program_info
  # 次の番組の録画開始後に現在の番組の録画の終了を検知するため、現在の番組の情報を保存する
  prev_curl_pid = program.pid
  prev_program_env = program.env.dup
  # 番組終了直前 MARGIN_SEC_FOR_NEXT_REC 秒まで待つ
  program.wait_rec_end
end
