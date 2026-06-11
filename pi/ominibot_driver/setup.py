from setuptools import setup

package_name = 'ominibot_driver'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='jarry',
    maintainer_email='jarry050599@gmail.com',
    description='Ominibot HV 萬向輪底盤驅動節點',
    license='MIT',
    entry_points={
        'console_scripts': [
            'ominibot_node = ominibot_driver.ominibot_node:main',
        ],
    },
)
