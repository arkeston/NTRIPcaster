#!/usr/bin/env python3
"""
web.py - Web管理模块
功能：提供前端接口，展示挂载点的实时信息，支持查看和查询挂载点解析数据
"""

import time
import json
import logging
import psutil
import re
from datetime import datetime
from functools import wraps
from threading import Thread

from flask import Flask, render_template_string, request, redirect, url_for, session, jsonify, send_from_directory
# from flask_cors import CORS  # 已移除，不需要CORS功能
import os
from flask_socketio import SocketIO, emit, join_room

from .database import DatabaseManager
from . import config
from . import logger
from .logger import log_debug, log_info, log_warning, log_error, log_critical, log_web_request, log_system_event
from . import connection
from . import forwarder
from .rtcm2_manager import parser_manager as rtcm_manager

# 全局服务器实例引用
server_instance = None

def set_server_instance(server):
    """设置服务器实例"""
    global server_instance
    server_instance = server

def get_server_instance():
    """获取服务器实例"""
    return server_instance

# 获取日志记录器
# web_logger = logger.get_logger('main')  # 已改用直接的log_函数

class WebManager:
    """Web管理器"""
    
    def __init__(self, db_manager, data_forwarder, start_time):
        self.db_manager = db_manager
        self.data_forwarder = data_forwarder
        self.start_time = start_time
        
        # 创建连接管理器实例
        global rtcm
        rtcm = connection.ConnectionManager()
        
        # 模板目录和静态文件目录
        self.template_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'templates')
        self.static_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'static')
        
        # 创建Flask应用
        self.app = Flask(__name__, static_folder=self.static_dir, static_url_path='/static')
        self.app.secret_key = config.FLASK_SECRET_KEY
        
        # 配置CORS - 已移除，项目为同域部署，不需要CORS功能
        # CORS(self.app, origins="*" if config.DEBUG else config.WEBSOCKET_CONFIG['cors_allowed_origins'])
        
        # 创建SocketIO实例
        # 在Windows上明确使用threading模式，避免eventlet兼容性问题
        # 移除CORS配置，项目为同域部署不需要跨域支持
        self.socketio = SocketIO(
            self.app, 
            async_mode='threading',  # 明确指定threading模式
            # cors_allowed_origins="*" if config.DEBUG else config.WEBSOCKET_CONFIG['cors_allowed_origins'],  # 已移除CORS
            ping_timeout=config.WEBSOCKET_CONFIG['ping_timeout'],
            ping_interval=config.WEBSOCKET_CONFIG['ping_interval']
        )
        
        # 注册路由
        self._register_routes()
        self._register_socketio_events()
        
        # 实时数据推送线程
        self.push_thread = None
        self.push_running = False
        
        # 设置logger的web实例引用，用于实时日志推送
        logger.set_web_instance(self)
    
    def _format_uptime_simple(self, uptime_seconds):
        """格式化运行时间（简单版本）"""
        try:
            days = int(uptime_seconds // 86400)
            hours = int((uptime_seconds % 86400) // 3600)
            minutes = int((uptime_seconds % 3600) // 60)
            
            if days > 0:
                return f"{days}days{hours}hours{minutes}min"
            elif hours > 0:
                return f"{hours}hours{minutes}min"
            else:
                return f"{minutes}min"
        except:
            return "0 minutes"
    
    def _validate_alphanumeric(self, value, field_name):
        """验证输入是否只包含英文字母、数字、下划线和中横线"""
        if not value:
            return False, f"{field_name}cannot be empty"
        
        # 允许英文字母、数字、下划线和中横线
        if not re.match(r'^[a-zA-Z0-9_-]+$', value):
            return False, f"{field_name}Must contain letters, numbers, underscores and horizontal lines only"
        
        return True, ""
    
    def _load_template(self, template_name, **kwargs):
        """加载外部模板文件"""
        template_path = os.path.join(self.template_dir, template_name)
        try:
            with open(template_path, 'r', encoding='utf-8') as f:
                template_content = f.read()
            return render_template_string(template_content, **kwargs)
        except FileNotFoundError:
            log_error(f"Template file not found:{template_path}")
            return f"<h1>Template file not found:{template_name}</h1>"
        except Exception as e:
            log_error(f"Failed to load template file:{e}")
            return f"<h1>Failed to load template:{str(e)}</h1>"
    
    def _register_routes(self):
        """注册Flask路由"""
        
        @self.app.route('/static/<path:filename>')
        def static_files(filename):
            """静态文件服务"""
            static_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'static')
            return send_from_directory(static_dir, filename)
        
        @self.app.route('/')
        def index():
            """主页 - SPA应用"""
            # 获取配置信息
            app_name = config.get_config_value('app', 'name', '2RTK NTRIP Caster')
            app_version = config.get_config_value('app', 'version', config.APP_VERSION)
            current_year = datetime.now().year
            
            return self._load_template('spa.html', 
                                     app_name=app_name,
                                     app_version=app_version,
                                     current_year=current_year,
                                     contact_email='i@jia.by',
                                     website_url='2RTK.COM')
        
        @self.app.route('/classic')
        @self.require_login
        def classic_index():
            """经典主页 - 系统状态和挂载点信息"""
            # 获取系统信息
            cpu_percent = psutil.cpu_percent(interval=1)
            memory = psutil.virtual_memory()
            uptime = time.time() - self.start_time
            
            # 获取运行中的挂载点
            running_mounts = self.db_manager.get_running_mounts()
            
            # 获取在线用户
            online_users = connection.get_connection_manager().get_online_users()
            
            # 获取RTCM解析数据
            parsed_data = connection.get_statistics().get('mounts', {})
            
            return self._load_template('index.html', 
                                        cpu_percent=cpu_percent,
                                        memory_percent=memory.percent,
                                        memory_used=memory.used // (1024*1024),
                                        memory_total=memory.total // (1024*1024),
                                        uptime=self._format_uptime(uptime),
                                        running_mounts=running_mounts,
                                        online_users=online_users,
                                        parsed_data=parsed_data)
        
        @self.app.route('/login', methods=['GET', 'POST'])
        def login():
            """登录页面"""
            if request.method == 'POST':
                # 表单验证
                username = request.form.get('username', '').strip()
                password = request.form.get('password', '').strip()
                
                # 防止空白提交
                if not username or not password:
                    return self._load_template('login.html', error="Username and password cannot be empty")
                
                # 长度验证
                if len(username) < 2 or len(username) > 50:
                    return self._load_template('login.html', error="Username must be between 2-50 characters long")
                
                if len(password) < 6 or len(password) > 100:
                    return self._load_template('login.html', error="Password length must be between 6-100 characters")
                
                # 验证用户名字符
                username_valid, username_error = self._validate_alphanumeric(username, "Username")
                if not username_valid:
                    return self._load_template('login.html', error=username_error)
                
                # 验证密码字符
                password_valid, password_error = self._validate_alphanumeric(password, "Password")
                if not password_valid:
                    return self._load_template('login.html', error=password_error)
                
                if self.db_manager.verify_admin(username, password):
                    session['admin_logged_in'] = True
                    session['admin_username'] = username
                    
                    # 检查重定向参数
                    redirect_page = request.args.get('redirect')
                    if redirect_page and redirect_page in ['users', 'mounts', 'settings']:
                        return redirect(f'/?page={redirect_page}')
                    
                    return redirect(url_for('index'))
                else:
                    return self._load_template('login.html', error="Incorrect username or password")
            
            return self._load_template('login.html')
        
        @self.app.route('/logout', methods=['GET', 'POST'])
        def logout():
            """登出"""
            session.clear()
            if request.method == 'POST':
                return jsonify({'success': True})
            return redirect(url_for('login'))
        
        @self.app.route('/api/login', methods=['POST'])
        def api_login():
            """API登录"""
            try:
                data = request.get_json()
                if not data:
                    return jsonify({'error': 'Wrong request data format'}), 400
                
                username = data.get('username', '').strip()
                password = data.get('password', '').strip()
                
                # 防止空白提交
                if not username or not password:
                    return jsonify({'error': 'Username and password cannot be empty'}), 400
                
                # 长度验证
                if len(username) < 2 or len(username) > 50:
                    return jsonify({'error': 'Username must be between 2-50 characters long'}), 400
                
                if len(password) < 6 or len(password) > 100:
                    return jsonify({'error': 'Password length must be between 6-100 characters'}), 400
                
                # 防止SQL注入的基本字符检查
                if any(char in username for char in ["'", '"', ';', '--', '/*', '*/', 'xp_']):
                    return jsonify({'error': 'Username contains illegal characters'}), 400
                
                if self.db_manager.verify_admin(username, password):
                    session['admin_logged_in'] = True
                    session['admin_username'] = username
                    return jsonify({
                        'success': True,
                        'message': 'Login Successful',
                        'token': 'session_based'  # 使用session而不是JWT
                    })
                else:
                    return jsonify({'error': 'Incorrect username or password'}), 401
            except Exception as e:
                    log_error(f"API login failure:{e}")
                    return jsonify({'error': 'Login failed'}), 500

        
        @self.app.route('/api/mount_info/<mount>')
        @self.require_login
        def mount_info(mount):
            """获取指定挂载点的解析信息并返回给前端"""
            parsed_data = rtcm_manager.get_parsed_mount_data(mount)
            statistics = rtcm_manager.get_mount_statistics(mount)
            
            if parsed_data:
                return jsonify({
                    'success': True,
                    'data': parsed_data,
                    'statistics': statistics
                })
            else:
                return jsonify({
                    'success': False,
                    'message': 'The mount point data does not exist or is not parsed'
                })
        

        
        @self.app.route('/api/system/restart', methods=['POST'])
        @self.require_login
        def restart_system():
            """重启程序API"""
            try:
                import os
                import sys
                import threading
                
                def delayed_restart():
                    """延迟重启程序"""
                    time.sleep(1)  # 给响应时间返回
                    log_info("Admin request to restart program")
                    os._exit(0)  # 强制退出程序
                
                # 在新线程中执行重启
                restart_thread = threading.Thread(target=delayed_restart)
                restart_thread.daemon = True
                restart_thread.start()
                
                return jsonify({
                    'success': True,
                    'message': 'Program restart instruction sent'
                })
                
            except Exception as e:
                    log_error(f"Failed to restart the program:{e}")
                    return jsonify({
                        'success': False,
                        'error': str(e)
                    }), 500
        

        
        @self.app.route('/api/mount/<mount_name>/realtime')
        @self.require_login
        def api_get_mount_realtime(mount_name):
            """获取指定挂载点的实时解析数据"""
            try:
                realtime_data = rtcm_manager.get_parsed_mount_data(mount_name, limit=10)
                if realtime_data is None:
                    return jsonify({'error': 'Mount not found'}), 404
                return jsonify(realtime_data)
            except Exception as e:
                    log_error(f"Get mount points{mount_name}Real-time data failure:{e}")
                    return jsonify({'error': str(e)}), 500
        
        @self.app.route('/api/mount/initialize', methods=['POST'])
        @self.require_login
        def api_initialize_mount():
            """初始化挂载点"""
            try:
                data = request.get_json()
                mount_name = data.get('mount_name')
                if not mount_name:
                    return jsonify({'error': 'Mount name is required'}), 400
                
                connection.get_connection_manager().add_mount_connection(mount_name, '127.0.0.1', 'Web Interface')
                log_system_event(f"Mount point{mount_name}Initialization successful")
                return jsonify({'success': True, 'message': f'Mount {mount_name} initialized'})
            except Exception as e:
                log_error(f"Failed to initialize mount point:{e}")
                return jsonify({'error': str(e)}), 500
        

        

        
        @self.app.route('/api/bypass/stop-all', methods=['POST'])
        @self.require_login
        def api_stop_all_bypass_parsing():
            """停止所有挂载点的旁路解析"""
            try:
                rtcm_manager.stop_realtime_parsing()
                log_system_event("All mount point bypass resolution stopped successfully")
                return jsonify({'success': True, 'message': 'All bypass parsing stopped'})
            except Exception as e:
                log_error(f"Failed to stop all bypass resolution:{e}")
                return jsonify({'error': str(e)}), 500
        
        @self.app.route('/api/mount/<mount_name>/simulate', methods=['POST'])
        @self.require_login
        def api_simulate_mount_data(mount_name):
            """为挂载点模拟数据"""
            try:
                # 模拟数据功能暂时不可用
                log_system_event(f"Mount point{mount_name}Data simulation request (feature temporarily unavailable)")
                log_system_event(f"Mount point{mount_name}Data simulation started successfully")
                return jsonify({'success': True, 'message': f'Data simulation started for {mount_name}'})
            except Exception as e:
                log_error(f"Failed to simulate mount point data:{e}")
                return jsonify({'error': str(e)}), 500
        
        @self.app.route('/api/mount/<mount_name>/rtcm-parse/start', methods=['POST'])
        @self.require_login
        def api_start_rtcm_parsing(mount_name):
            """启动指定挂载点的实时RTCM解析"""
            try:
                # print(f"[后端API] 收到启动RTCM解析请求 - 挂载点: {mount_name}")
                
                # 注意：不再手动调用stop_realtime_parsing()，
                # 因为新的start_realtime_parsing方法已经内置了智能清理逻辑
                # print(f"[后端API] 准备启动解析任务，内置清理逻辑将自动处理前一个解析线程")
                
                # 定义推送回调：接收rtcm.py解析的数据并推送到前端
                def push_callback(parsed_data):
                    mount_name = parsed_data.get("mount_name", "N/A")
                    data_type = parsed_data.get("data_type", "N/A")
                    timestamp = parsed_data.get("timestamp", "N/A")
                    data_keys = list(parsed_data.keys()) if isinstance(parsed_data, dict) else "N/A"
                    
                    # print(f"\n[后端推送] 准备推送数据到前端:")
        # print(f"   挂载点: {mount_name}")
        # print(f"   数据类型: {data_type}")
        # print(f"   时间戳: {timestamp}")
        # print(f"   数据键: {data_keys}")
                    
                    # 详细打印不同类型的数据
                    if data_type == 'msm_satellite':
                        # MSM卫星数据调试信息已注释，避免刷屏
                        # print(f"   MSM卫星数据详情:")
                        # print(f"      GNSS类型: {parsed_data.get('gnss', 'N/A')}")
                        # print(f"      消息类型: {parsed_data.get('msg_type', 'N/A')}")
                        # print(f"      MSM等级: {parsed_data.get('msm_level', 'N/A')}")
                        # print(f"      卫星数量: {parsed_data.get('total_sats', 'N/A')}")
                        # if 'sats' in parsed_data and isinstance(parsed_data['sats'], list):
                        #     print(f"      前3个卫星数据:")
                        #     for i, sat in enumerate(parsed_data['sats'][:3]):
                        #         print(f"        卫星{i+1}: PRN={sat.get('id', 'N/A')}, SNR={sat.get('snr', 'N/A')}, 信号={sat.get('signal_type', 'N/A')}")
                        #     if len(parsed_data['sats']) > 3:
                        #         print(f"        ... 还有 {len(parsed_data['sats']) - 3} 个卫星")
                        pass
                    elif data_type == 'geography':
                        # print(f"   地理位置数据详情:")
                        # print(f"      基准站ID: {parsed_data.get('station_id', 'N/A')}")
                        # print(f"      纬度: {parsed_data.get('lat', 'N/A')}")
                        # print(f"      经度: {parsed_data.get('lon', 'N/A')}")
                        # print(f"      高度: {parsed_data.get('height', 'N/A')}")
                        # print(f"      国家: {parsed_data.get('country', 'N/A')}")
                        # print(f"      城市: {parsed_data.get('city', 'N/A')}")
                        pass
                    elif data_type == 'device_info':
                        # print(f"   设备信息数据详情:")
                        # print(f"      接收机: {parsed_data.get('receiver', 'N/A')}")
                        # print(f"      固件版本: {parsed_data.get('firmware', 'N/A')}")
                        # print(f"      天线: {parsed_data.get('antenna', 'N/A')}")
                        # print(f"      天线固件: {parsed_data.get('antenna_firmware', 'N/A')}")
                        pass
                    elif data_type == 'message_stats':
                        # print(f"   消息统计数据详情:")
                        # print(f"      消息类型: {parsed_data.get('message_types', 'N/A')}")
                        # print(f"      GNSS系统: {parsed_data.get('gnss', 'N/A')}")
                        # print(f"      载波频段: {parsed_data.get('carriers', 'N/A')}")
                        pass
                    
                    # 打印完整数据（截断显示）- 对MSM数据不打印以避免刷屏
                    if data_type != 'msm_satellite':
                        data_str = str(parsed_data)
                        # print(f"   完整数据: {data_str[:500]}{'...' if len(data_str) > 500 else ''}")
                    
                    # 确保数据包含mount_name
                    if 'mount_name' not in parsed_data:
                        # print(f"[后端推送] 推送数据缺少mount_name字段")
                        log_warning("Missing mount_name field for push data")
                        return
                        
                    # 通过SocketIO推送给前端，事件名为'rtcm_realtime_data'
                    if data_type != 'msm_satellite':
                        # print(f"[后端推送] 通过SocketIO推送数据到前端 - 事件: rtcm_realtime_data")
                        pass
                    self.socketio.emit(
                        'rtcm_realtime_data',
                        parsed_data
                    )
                    if data_type != 'msm_satellite':
                        # print(f"[后端推送] 数据推送完成\n")
                        pass
                
                # 启动新的解析任务，传入回调
                # print(f"[后端API] 启动新的解析任务 - 挂载点: {mount_name}")
                success = rtcm_manager.start_realtime_parsing(
                    mount_name=mount_name,
                    push_callback=push_callback  # 替换原有的self.socketio参数
                )
                if success:
                    # print(f" [后端API] 解析启动成功 - 挂载点: {mount_name}")
                    log_system_event(f"Mount point{mount_name}Real-time RTCM resolution started")
                    return jsonify({'success': True, 'message': f'Real-time RTCM parsing started for {mount_name}'})
                else:
                    # print(f"[后端API] 解析启动失败 - 挂载点: {mount_name} (可能离线)")
                    return jsonify({'error': 'Failed to start parsing - mount may be offline'}), 400
            except Exception as e:
                # print(f"[后端API] 启动RTCM解析异常: {e}")
                log_error(f"Failed to start real-time RTCM parsing:{e}")
                return jsonify({'error': str(e)}), 500
        
        @self.app.route('/api/mount/rtcm-parse/stop', methods=['POST'])
        @self.require_login
        def api_stop_rtcm_parsing():
            """停止所有实时RTCM解析"""
            try:
                rtcm_manager.stop_realtime_parsing()
                log_system_event("All real-time RTCM resolution stopped")
                return jsonify({'success': True, 'message': 'Real-time RTCM parsing stopped'})
            except Exception as e:
                log_error(f"Failed to stop real-time RTCM parsing:{e}")
                return jsonify({'error': str(e)}), 500
        
        @self.app.route('/api/mount/rtcm-parse/status', methods=['GET'])
        @self.require_login
        def api_get_rtcm_parsing_status():
            """获取RTCM解析器状态信息"""
            try:
                status = rtcm_manager.get_parser_status()
                return jsonify({
                    'success': True, 
                    'status': status,
                    'message': 'Parser status retrieved successfully'
                })
            except Exception as e:
                log_error(f"Failed to get parser status:{e}")
                return jsonify({'error': str(e)}), 500
        
        @self.app.route('/api/mount/rtcm-parse/heartbeat', methods=['POST'])
        @self.require_login
        def api_rtcm_parsing_heartbeat():
            """实时RTCM解析心跳维持"""
            try:
                data = request.get_json()
                mount_name = data.get('mount_name') if data else None
                
                if mount_name:
                    # 更新心跳时间戳
                    rtcm_manager.update_parsing_heartbeat(mount_name)
                    return jsonify({'success': True, 'message': 'Heartbeat updated'})
                else:
                    return jsonify({'error': 'Mount name is required'}), 400
            except Exception as e:
                log_error(f"Update resolution heartbeat failed:{e}")
                return jsonify({'error': str(e)}), 500
        


        
        @self.app.route('/alipay_qr')
        def alipay_qr():
            """支付宝二维码"""
            return redirect(config.ALIPAY_QR_URL)
        
        @self.app.route('/wechat_qr')
        def wechat_qr():
            """微信二维码"""
            return redirect(config.WECHAT_QR_URL)
        

        @self.app.route('/api/app_info')
        def api_app_info():
            """获取应用信息"""
            try:
                return jsonify({
                    'name': config.APP_NAME,
                    'version': config.APP_VERSION,
                    'description': config.APP_DESCRIPTION,
                    'author': config.APP_AUTHOR,
                    'contact': config.APP_CONTACT,
                    'website': config.APP_WEBSITE
                })
            except Exception as e:
                log_error(f"Failed to get app info:{e}")
                return jsonify({'error': str(e)}), 500
        
        @self.app.route('/api/users', methods=['GET', 'POST'])
        @self.require_login
        def api_users():
            """用户管理API"""
            if request.method == 'GET':
                # 获取用户列表
                try:
                    users = self.db_manager.get_all_users()
                    
                    # 获取在线用户信息
                    try:
                        online_users = connection.get_connection_manager().get_online_users()
                        online_usernames = list(online_users.keys())
                    except Exception as e:
                        log_error(f"Failed to get online users:{e}")
                        online_usernames = []
                    
                    # 将tuple转换为字典格式并添加在线状态和连接数
                    user_list = []
                    for user in users:
                        username = user[1]
                        connection_count = connection.get_connection_manager().get_user_connection_count(username)
                        connect_time = connection.get_connection_manager().get_user_connect_time(username)
                        user_dict = {
                            'id': user[0],
                            'username': username,
                            'online': username in online_usernames,
                            'connection_count': connection_count,
                            'connect_time': connect_time or '-'  # 接入时间
                        }
                        user_list.append(user_dict)
                    
                    return jsonify(user_list)
                except Exception as e:
                    log_error(f"Failed to get user list:{e}")
                    return jsonify({'error': str(e)}), 500
            
            elif request.method == 'POST':
                # 添加用户
                try:
                    data = request.get_json()
                    if not data:
                        return jsonify({'error': 'Wrong request data format'}), 400
                    
                    username = data.get('username', '').strip()
                    password = data.get('password', '').strip()
                    
                    # 表单验证
                    if not username or not password:
                        return jsonify({'error': 'Username and password cannot be empty'}), 400
                    
                    # 验证用户名字符
                    username_valid, username_error = self._validate_alphanumeric(username, "Username")
                    if not username_valid:
                        return jsonify({'error': username_error}), 400
                    
                    # 验证密码字符
                    password_valid, password_error = self._validate_alphanumeric(password, "Password")
                    if not password_valid:
                        return jsonify({'error': password_error}), 400
                    
                    elif len(username) < 2 or len(username) > 50:
                        return jsonify({'error': 'Username must be between 2-50 characters long'}), 400
                    elif len(password) < 6 or len(password) > 100:
                        return jsonify({'error': 'Password length must be between 6-100 characters'}), 400
                    
                    # 检查用户是否已存在
                    existing_users = [u[1] for u in self.db_manager.get_all_users()]
                    if username in existing_users:
                        return jsonify({'error': 'Username already exists'}), 400
                    
                    success, message = self.db_manager.add_user(username, password)
                    if success:
                        return jsonify({'message': message}), 201
                    else:
                        return jsonify({'error': message}), 400
                    
                except Exception as e:
                    log_error(f"Failed to add user:{e}")
                    return jsonify({'error': str(e)}), 500
        
        @self.app.route('/api/users/<username>', methods=['PUT', 'DELETE'])
        @self.require_login
        def api_user_detail(username):
            """用户详情管理API"""
            if request.method == 'PUT':
                # 更新用户信息（密码或用户名）
                try:
                    data = request.get_json()
                    if not data:
                        return jsonify({'error': 'Wrong request data format'}), 400
                    
                    new_password = data.get('password', '').strip()
                    new_username = data.get('username', '').strip()
                    
                    # 检查是否是管理员账户
                    if username == config.DEFAULT_ADMIN['username']:
                        # 管理员只能修改密码，不能修改用户名
                        if new_username:
                            return jsonify({'error': 'Administrator username cannot be modified'}), 400
                        
                        if not new_password:
                            return jsonify({'error': 'New password cannot be empty'}), 400
                        
                        # 验证密码字符
                        password_valid, password_error = self._validate_alphanumeric(new_password, "New password")
                        if not password_valid:
                            return jsonify({'error': password_error}), 400
                        
                        elif len(new_password) < 6 or len(new_password) > 100:
                            return jsonify({'error': 'New password must be between 6-100 characters long'}), 400
                        
                        # 管理员密码更新
                        success = self.db_manager.update_admin_password(username, new_password)
                        if success:
                            return jsonify({'message': f'Administrator{username}Password updated successfully'})
                        else:
                            return jsonify({'error': 'Admin password update failed'}), 500
                    else:
                        # 普通用户可以修改密码和用户名
                        if new_username:
                            # 修改用户名
                            # 验证用户名字符
                            username_valid, username_error = self._validate_alphanumeric(new_username, "Username")
                            if not username_valid:
                                return jsonify({'error': username_error}), 400
                            
                            if len(new_username) < 2 or len(new_username) > 50:
                                return jsonify({'error': 'Username must be between 2-50 characters long'}), 400
                            
                            # 检查新用户名是否已存在
                            existing_users = [u[1] for u in self.db_manager.get_all_users()]
                            if new_username in existing_users and new_username != username:
                                return jsonify({'error': 'Username already exists'}), 400
                            
                            # 强制下线用户
                            forwarder.force_disconnect_user(username)
                            
                            # 获取用户ID和当前密码
                            users = self.db_manager.get_all_users()
                            user_id = None
                            current_password = None
                            for user in users:
                                if user[1] == username:
                                    user_id = user[0]
                                    current_password = user[2]  # 获取当前密码哈希
                                    break
                            
                            if user_id is None:
                                return jsonify({'error': 'User does not exist'}), 400
                            
                            # 更新用户名（保持原密码）
                            success, message = self.db_manager.update_user(user_id, new_username, current_password)
                            if success:
                                return jsonify({'message': f'Username from{username}Updated to{new_username}'})
                            else:
                                return jsonify({'error': message}), 400
                        
                        elif new_password:
                            # 修改密码
                            if len(new_password) < 6 or len(new_password) > 100:
                                return jsonify({'error': 'New password must be between 6-100 characters long'}), 400
                            
                            # 强制下线用户
                            forwarder.force_disconnect_user(username)
                            success, message = self.db_manager.update_user_password(username, new_password)
                            if success:
                                return jsonify({'message': f'User{username}Password updated successfully'})
                            else:
                                return jsonify({'error': message}), 400
                        else:
                            return jsonify({'error': 'Please provide a password or username to update'}), 400
                    
                except Exception as e:
                    log_error(f"Failed to update user:{e}")
                    return jsonify({'error': str(e)}), 500
            
            elif request.method == 'DELETE':
                # 删除用户
                try:
                    # 强制下线用户
                    forwarder.force_disconnect_user(username)
                    success, result = self.db_manager.delete_user(username)
                    if success:
                        return jsonify({'message': f'User{result}deleted successfully'})
                    else:
                        return jsonify({'error': result}), 400
                    
                except Exception as e:
                    log_error(f"Failed to delete user:{e}")
                    return jsonify({'error': str(e)}), 500
        
        @self.app.route('/api/mounts', methods=['GET', 'POST'])
        @self.require_login
        def api_mounts():
            """挂载点管理API"""
            if request.method == 'GET':
                # 获取挂载点列表
                try:
                    mounts = self.db_manager.get_all_mounts()
                    online_mounts = connection.get_connection_manager().get_online_mounts()
                    
                    # 将tuple转换为字典格式并添加运行状态和连接信息
                    mount_list = []
                    for mount in mounts:
                        mount_name = mount[1]
                        is_online = mount_name in online_mounts
                        # 获取实际的数据率
                        data_rate_str = '0 B/s'
                        if is_online:
                            mount_info = connection.get_connection_manager().get_mount_info(mount_name)
                            if mount_info and 'data_rate' in mount_info:
                                data_rate_bps = mount_info['data_rate']
                                if data_rate_bps >= 1024:
                                    data_rate_str = f'{data_rate_bps/1024:.2f} KB/s'
                                else:
                                    data_rate_str = f'{data_rate_bps:.2f} B/s'
                        
                        mount_dict = {
                            'id': mount[0],
                            'mount': mount_name,
                            'password': mount[2],
                            'username': mount[4] if len(mount) > 4 else None,  # 用户名
                            'lat': mount[5] if len(mount) > 5 and mount[5] is not None else 0,
                            'lon': mount[6] if len(mount) > 6 and mount[6] is not None else 0,
                            'active': is_online,
                            'connections': connection.get_connection_manager().get_mount_connection_count(mount_name) if is_online else 0,
                            'data_rate': data_rate_str
                        }
                        mount_list.append(mount_dict)
                    
                    return jsonify(mount_list)
                except Exception as e:
                    log_error(f"Failed to get mount point list:{e}")
                    return jsonify({'error': str(e)}), 500
            
            elif request.method == 'POST':
                # 添加挂载点
                try:
                    data = request.get_json()
                    if not data:
                        return jsonify({'error': 'Wrong request data format'}), 400
                    
                    mount = data.get('mount', '').strip()
                    password = data.get('password', '').strip()
                    user_id = data.get('user_id')  # 可选的用户ID参数
                    
                    # 表单验证
                    if not mount or not password:
                        return jsonify({'error': 'Mountpoint name and password cannot be empty'}), 400
                    
                    # 验证挂载点名称字符
                    mount_valid, mount_error = self._validate_alphanumeric(mount, "Mount Point Name")
                    if not mount_valid:
                        return jsonify({'error': mount_error}), 400
                    
                    # 验证密码字符
                    password_valid, password_error = self._validate_alphanumeric(password, "Password")
                    if not password_valid:
                        return jsonify({'error': password_error}), 400
                    
                    elif len(mount) < 2 or len(mount) > 50:
                        return jsonify({'error': 'Mount point name must be between 2-50 characters long'}), 400
                    elif len(password) < 6 or len(password) > 100:
                        return jsonify({'error': 'Password length must be between 6-100 characters'}), 400
                    
                    # 如果指定了user_id，验证用户是否存在
                    if user_id is not None:
                        try:
                            user_id = int(user_id)
                            users = self.db_manager.get_all_users()
                            user_ids = [u[0] for u in users]  # u[0] 是用户ID
                            if user_id not in user_ids:
                                return jsonify({'error': 'The specified user does not exist'}), 400
                        except (ValueError, TypeError):
                            return jsonify({'error': 'Wrong user ID format'}), 400
                    
                    # 检查挂载点是否已存在
                    existing_mounts = [m[1] for m in self.db_manager.get_all_mounts()]
                    if mount in existing_mounts:
                        return jsonify({'error': 'Mount point already exists'}), 400
                    
                    success, message = self.db_manager.add_mount(mount, password, user_id)
                    if success:
                        return jsonify({'message': message}), 201
                    else:
                        return jsonify({'error': message}), 400
                    
                except Exception as e:
                    log_error(f"Failed to add mount point:{e}")
                    return jsonify({'error': str(e)}), 500
        
        @self.app.route('/api/mounts/<mount_name>', methods=['PUT', 'DELETE'])
        @self.require_login
        def api_mount_detail(mount_name):
            """挂载点详情管理API"""
            if request.method == 'PUT':
                # 更新挂载点
                try:
                    data = request.get_json()
                    if not data:
                        return jsonify({'error': 'Wrong request data format'}), 400
                    
                    new_password = data.get('password', '').strip()
                    new_mount_name = data.get('mount_name', '').strip()
                    new_user_id = data.get('user_id')
                    username = data.get('username')
                    
                    # 验证新挂载点名称
                    if new_mount_name:
                        # 验证挂载点名称字符
                        mount_valid, mount_error = self._validate_alphanumeric(new_mount_name, "Mount Point Name")
                        if not mount_valid:
                            return jsonify({'error': mount_error}), 400
                        
                        if len(new_mount_name) < 2 or len(new_mount_name) > 50:
                            return jsonify({'error': 'Mount point name must be between 2-50 characters long'}), 400
                        
                        # 检查新挂载点名称是否已存在
                        existing_mounts = [m[1] for m in self.db_manager.get_all_mounts()]
                        if new_mount_name in existing_mounts and new_mount_name != mount_name:
                            return jsonify({'error': 'Mount point name already exists'}), 400
                    
                    # 处理用户绑定（支持用户名和用户ID两种方式）
                    if username is not None:
                        if username == "" or (isinstance(username, str) and username.lower() == "null"):
                            new_user_id = None  # 空字符串或"null"表示解除绑定
                        else:
                            # 验证用户名字符
                            username_valid, username_error = self._validate_alphanumeric(username, "Username")
                            if not username_valid:
                                return jsonify({'error': username_error}), 400
                            
                            # 通过用户名查找用户ID
                            users = self.db_manager.get_all_users()
                            user_found = False
                            for user in users:
                                if user[1] == username:  # user[1] 是用户名
                                    new_user_id = user[0]  # user[0] 是用户ID
                                    user_found = True
                                    break
                            if not user_found:
                                return jsonify({'error': f'User "{username}"Does not exist'}), 400
                    elif new_user_id is not None:
                        # 兼容原有的用户ID方式
                        if new_user_id == "" or (isinstance(new_user_id, str) and new_user_id.lower() == "null"):
                            new_user_id = None  # 空字符串或"null"转换为None
                        elif new_user_id is not None:
                            try:
                                new_user_id = int(new_user_id)
                                # 检查用户是否存在
                                users = self.db_manager.get_all_users()
                                user_exists = any(user[0] == new_user_id for user in users)
                                if not user_exists:
                                    return jsonify({'error': 'The specified user does not exist'}), 400
                            except (ValueError, TypeError):
                                return jsonify({'error': 'Wrong user ID format'}), 400
                    
                    if new_password:
                        # 验证密码字符
                        password_valid, password_error = self._validate_alphanumeric(new_password, "Password")
                        if not password_valid:
                            return jsonify({'error': password_error}), 400
                        
                        if len(new_password) < 6 or len(new_password) > 100:
                            return jsonify({'error': 'New password must be between 6-100 characters long'}), 400
                    
                    # 强制下线挂载点
                    forwarder.force_disconnect_mount(mount_name)
                    
                    # 获取挂载点ID
                    mounts = self.db_manager.get_all_mounts()
                    mount_id = None
                    for mount in mounts:
                        if mount[1] == mount_name:  # mount[1] 是挂载点名称
                            mount_id = mount[0]  # mount[0] 是ID
                            break
                    
                    if mount_id is None:
                        return jsonify({'error': 'Mount point does not exist'}), 400
                    
                    # 使用update_mount函数更新挂载点信息
                    success, result = self.db_manager.update_mount(
                        mount_id, 
                        new_mount_name if new_mount_name else None,
                        new_password if new_password else None,
                        new_user_id
                    )
                    if success:
                        # 构建返回消息
                        messages = []
                        if new_mount_name:
                            messages.append(f'Mount point name from{mount_name}Updated to{new_mount_name}')
                        if new_password:
                            messages.append('Mountpoint password updated')
                        if 'username' in data or new_user_id is not None:
                            if new_user_id is None:
                                messages.append('Mount point belongs to user cleared')
                            else:
                                if username and username != "":
                                    messages.append(f'The user belonging to the mount point has been updated to{username}')
                                else:
                                    messages.append(f'The user belonging to the mount point has been updated to the user ID{new_user_id}')
                        
                        if not messages:
                            messages.append('Mount point information updated successfully')
                        
                        return jsonify({'message': '; '.join(messages)})
                    else:
                        return jsonify({'error': result}), 400
                    
                except Exception as e:
                    log_error(f"Failed to update mount point:{e}")
                    return jsonify({'error': str(e)}), 500
            
            elif request.method == 'DELETE':
                # 删除挂载点
                try:
                    # 获取挂载点ID
                    mounts = self.db_manager.get_all_mounts()
                    mount_id = None
                    for mount in mounts:
                        if mount[1] == mount_name:  # mount[1] 是挂载点名称
                            mount_id = mount[0]  # mount[0] 是ID
                            break
                    
                    if mount_id is None:
                        return jsonify({'error': 'Mount point does not exist'}), 400
                    
                    # 强制下线挂载点
                    forwarder.force_disconnect_mount(mount_name)
                    success, result = self.db_manager.delete_mount(mount_name)
                    if success:
                        # 清理挂载点连接数据
                        connection.get_connection_manager().remove_mount_connection(mount_name)
                        return jsonify({'message': f'Mount point{result}deleted successfully'})
                    else:
                        return jsonify({'error': result}), 400
                    
                except Exception as e:
                    log_error(f"Failed to delete mount point:{e}")
                    return jsonify({'error': str(e)}), 500

        

        

        
        @self.app.route('/api/mount/<mount_name>/online')
        @self.require_login
        def api_mount_online_status(mount_name):
            """检查挂载点是否在线"""
            try:
                is_online = connection.is_mount_online(mount_name)
                mount_info = None
                if is_online:
                    mount_info = connection.get_connection_manager().get_mount_info(mount_name)
                
                return jsonify({
                    'mount_name': mount_name,
                    'online': is_online,
                    'mount_info': mount_info
                })
            except Exception as e:
                log_error(f"Failed to check mount point online status:{e}")
                return jsonify({'error': str(e)}), 500
        
        @self.app.route('/api/system/stats')
        def api_system_stats():
            """获取系统统计数据"""
            try:
                # 获取服务器实例
                server = get_server_instance()
                if server and hasattr(server, 'get_system_stats'):
                    stats = server.get_system_stats()
                
                    return jsonify(stats)
                else:
                    log_error("API error: Could not get server instance or get_system_stats method")
                    return jsonify({'error': 'Unable to get system statistics'}), 500
            except Exception as e:
                log_error(f"API exception: Failed to get system statistics:{e}")
                return jsonify({'error': str(e)}), 500
        
        @self.app.route('/api/str-table', methods=['GET'])
        def api_str_table():
            """获取实时STR表数据"""
            try:
                # 获取所有在线挂载点的STR数据
                cm = connection.get_connection_manager()
                str_data = cm.get_all_str_data()
                
                # 生成完整的挂载点列表（包括STR表）
                mount_list = cm.generate_mount_list()
                
                return jsonify({
                    'success': True,
                    'str_data': str_data,
                    'mount_list': mount_list,
                    'timestamp': time.time()
                })
            except Exception as e:
                log_error(f"Failed to get Str table:{e}")
                return jsonify({
                    'success': False,
                    'error': str(e)
                }), 500
        
        @self.app.route('/api/mounts/online', methods=['GET'])
        def api_online_mounts_detailed():
            """获取详细的在线挂载点信息"""
            try:
                cm = connection.get_connection_manager()
                online_mounts = cm.get_online_mounts()
                
                # 为每个挂载点添加详细信息
                detailed_mounts = {}
                for mount_name, mount_info in online_mounts.items():
                    detailed_mounts[mount_name] = {
                        'basic_info': mount_info,
                        'str_data': cm.get_mount_str_data(mount_name),
                        'statistics': cm.get_mount_statistics(mount_name),
                        'connection_count': cm.get_mount_connection_count(mount_name)
                    }
                
                return jsonify({
                    'success': True,
                    'online_mounts': detailed_mounts,
                    'total_count': len(detailed_mounts),
                    'timestamp': time.time()
                })
            except Exception as e:
                log_error(f"Get mount points{mount_name}Historical data failed:{e}")
                return jsonify({
                    'success': False,
                    'error': str(e)
                }), 500
        
        @self.app.route('/api/mount/<mount_name>/rtcm-parse/history', methods=['GET'])
        @self.require_login
        def api_get_rtcm_history(mount_name):
            """获取指定挂载点的历史解析数据"""
            try:
                # 获取解析结果
                parsed_data = rtcm_manager.get_parsed_mount_data(mount_name)
                if parsed_data:
                    return jsonify({
                        'success': True,
                        'data': parsed_data
                    })
                else:
                    return jsonify({
                        'success': False,
                        'error': 'No data available for this mount point'
                    }), 404
            except Exception as e:
                log_error(f"Get mount points{mount_name}Historical data failed:{e}")
                return jsonify({'error': str(e)}), 500

    
    def _ensure_forwarder_started(self):
        """确保forwarder已启动（已在main.py中启动，此方法保留用于兼容性）"""
        # forwarder已经在main.py中启动，这里不需要重复启动
        pass
    
    def _register_socketio_events(self):
        """注册SocketIO事件"""
        
        @self.socketio.on('connect')
        def handle_connect():
            """客户端连接"""
            from flask import session
            client_id = session.get('sid', 'unknown')
            log_web_request('websocket', 'connect', client_id, 'WebSocket client disconnected')
            # 将客户端加入到数据推送房间
            join_room('data_push')
            if config.LOG_FREQUENT_STATUS:
                log_info(f"Client{client_id}joined data_push room")
            emit('status', {'message': 'Connection successful'})
        
        @self.socketio.on('disconnect')
        def handle_disconnect():
            """客户端断开连接"""
            from flask import session
            client_id = session.get('sid', 'unknown')
            log_web_request('websocket', 'disconnect', client_id, 'WebSocket client disconnected')
            
            # 当WebSocket连接断开时，自动清理Web解析线程
            try:
                # 获取当前活跃的Web解析挂载点
                current_web_mount = rtcm_manager.get_current_web_mount()
                if current_web_mount:
                    log_info(f"WebSocket disconnected, automatically cleaned up web resolution thread [Mount point:{current_web_mount}]")
                    rtcm_manager.stop_realtime_parsing()
                    log_system_event(f"WebSocket disconnected Automatic cleanup of web resolution threads:{current_web_mount}")
                else:
                    log_debug("WebSocket disconnected but no active web resolution thread to clean")
            except Exception as e:
                log_error(f"Failed to clean up web resolution thread when WebSocket is disconnected:{e}")
        
        @self.socketio.on('request_mount_data')
        def handle_request_mount_data(data):
            """请求挂载点数据"""
            mount = data.get('mount')
            if mount:
                parsed_data = rtcm_manager.get_parsed_mount_data(mount)
                statistics = rtcm_manager.get_mount_statistics(mount)
                emit('mount_data', {
                    'mount': mount,
                    'data': parsed_data,
                    'statistics': statistics
                })
        
        @self.socketio.on('request_recent_data')
        def handle_request_recent_data(data):
            """前端请求挂载点最近解析的数据"""
            mount_name = data.get('mount_name')
            if mount_name:
                recent_data = rtcm_manager.get_parsed_mount_data(mount_name)
                emit('recent_data_response', {
                    'mount_name': mount_name,
                    'data': recent_data
                })
        
        @self.socketio.on('request_system_stats')
        def handle_request_system_stats():
            """请求系统统计数据"""
            try:
                server = get_server_instance()
                if server and hasattr(server, 'get_system_stats'):
                    stats = server.get_system_stats()
                    if stats:
                        emit('system_stats_update', {
                            'stats': stats,
                            'timestamp': time.time()
                        })
                    else:
                        emit('error', {'message': 'Unable to get system statistics'})
                else:
                    emit('error', {'message': 'Server instance not available'})
            except Exception as e:
                log_error(f"Failed to process system statistics request:{e}")
                emit('error', {'message': str(e)})
    
    def require_login(self, f):
        """登录装饰器"""
        @wraps(f)
        def decorated_function(*args, **kwargs):
            if not session.get('admin_logged_in'):
                # 检查是否是API请求
                if request.path.startswith('/api/'):
                    return jsonify({'error': 'Not logged in or login expired'}), 401
                else:
                    return redirect(url_for('login'))
            return f(*args, **kwargs)
        return decorated_function
    
    def start_rtcm_parsing(self):
        """启动RTCM解析进程，持续解析数据并推送到前端"""
        # 现在RTCM解析集成在connection_manager中，无需单独启动
        
        # 启动实时数据推送
        if not self.push_running:
            self.push_running = True
            self.push_thread = Thread(target=self._push_data_loop, daemon=True)
            self.push_thread.start()
            log_system_event('Web real-time data push started')
    
    def stop_rtcm_parsing(self):
        """停止RTCM解析"""
        # 现在RTCM解析集成在connection_manager中，无需单独停止
        
        # 停止实时数据推送
        if self.push_running:
            self.push_running = False
            if self.push_thread:
                self.push_thread.join(timeout=5)
            log_system_event('Web real-time data push stopped')
    
    def _push_data_loop(self):
        """实时数据推送循环"""
        log_info("Data push cycle started")
        while self.push_running:
            try:
                # 推送系统统计数据
                server = get_server_instance()
                if server and hasattr(server, 'get_system_stats'):
                    stats = server.get_system_stats()
                    if stats:
                        self.socketio.emit('system_stats_update', {
                            'stats': stats,
                            'timestamp': time.time()
                        }, to='data_push')
                        # 移除调试日志输出
                pass
                
                # 推送在线用户列表
                online_users = connection.get_connection_manager().get_online_users()
                self.socketio.emit('online_users_update', {
                    'users': online_users,
                    'timestamp': time.time()
                }, to='data_push')
                # 移除调试日志输出
                pass
                
                # 推送在线挂载点列表
                online_mounts = connection.get_connection_manager().get_online_mounts()
                self.socketio.emit('online_mounts_update', {
                    'mounts': online_mounts,
                    'timestamp': time.time()
                }, to='data_push')
                # 移除调试日志输出
                pass
                
                # 推送STR表数据
                str_data = connection.get_connection_manager().get_all_str_data()
                self.socketio.emit('str_data_update', {
                    'str_data': str_data,
                    'timestamp': time.time()
                }, to='data_push')
                # 移除调试日志输出
                pass
                
                time.sleep(config.REALTIME_PUSH_INTERVAL)
            except Exception as e:
                log_error(f"Data push exception:{e}", exc_info=True)
                time.sleep(1)
    
    def push_log_message(self, message, log_type='info'):
        """推送日志消息到前端"""
        try:
            self.socketio.emit('log_message', {
                'message': message,
                'type': log_type,
                'timestamp': time.time()
            }, to='data_push')
        except Exception as e:
            log_error(f"Push log message failed:{e}")
    
    def _format_uptime(self, uptime_seconds):
        """格式化运行时间"""
        days = int(uptime_seconds // 86400)
        hours = int((uptime_seconds % 86400) // 3600)
        minutes = int((uptime_seconds % 3600) // 60)
        seconds = int(uptime_seconds % 60)
        
        if days > 0:
            return f"{days}days{hours}hours{minutes}min"
        elif hours > 0:
            return f"{hours}hours{minutes}min"
        else:
            return f"{minutes}min{seconds}s"
    

    
    def run(self, host=None, port=None, debug=None):
        """启动Web服务器"""
        host = host or config.HOST
        port = port or config.WEB_PORT
        debug = debug if debug is not None else config.DEBUG
        self.socketio.run(self.app, host=host, port=port, debug=debug, allow_unsafe_werkzeug=True)
    

# 便捷函数
def create_web_manager(db_manager, data_forwarder, start_time):
    """创建Web管理器实例"""
    return WebManager(db_manager, data_forwarder, start_time)