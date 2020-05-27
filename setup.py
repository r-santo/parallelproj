import setuptools
import os
from glob import glob
import platform

#-----------
# find all compiled C / CUDA libs
plt = platform.system()

if plt == 'Linux':
  lib_files = glob('lib/*.so')
elif plt == 'Windows':
  lib_files = glob('lib/*.dll')
else:
  raise SystemError(f'{platform.system()} not supported yet.')

#-----------

setuptools.setup(
    name="pyparallelproj",
    use_scm_version={'fallback_version':'unkown'},
    setup_requires=['setuptools_scm', 'setuptools_scm_git_archive'],
    author="Georg Schramm,",
    author_email="georg.schramm@kuleuven.be",
    description="CUDA and OPENMP PET projectors with python bindings",
    license='MIT',
    long_description_content_type="text/markdown",
    url="https://github.com/gschramm/parallelproj",
    packages=setuptools.find_packages(),
    classifiers=[
        "Programming Language :: Python :: 3",
        "License :: OSI Approved :: MIT License",
        "Operating System :: OS Independent",
    ],
    python_requires='>=3.7',
    install_requires=['numpy>=1.18',
                      'matplotlib>=3.2.1'],
    data_files = [('lib', lib_files)]
)
